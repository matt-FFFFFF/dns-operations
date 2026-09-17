# CI

Four workflows. Each one fans out to a matrix with one job per zone, because
each zone has its own Terraform state file and so its own lock, its own blast
radius and its own failure.

| workflow | when | zones | environment | writes DNS |
| --- | --- | --- | --- | --- |
| `validate` | pull request, push to main | changed | `plan` | no |
| `apply` | push to main, manual | changed | `production` | yes |
| `drift` | nightly 06:17 UTC, manual | **all** | `plan` | no |
| `reconcile` | manual only | chosen | `plan` or `production` | on `mode=apply` |

## Which zones a change affects

`tools/changed-zones.sh` is the only thing that answers this, and every
workflow asks it rather than deciding for itself. There is deliberately no
`paths:` filter on any trigger: a filter is a second place that decides what
matters, and it is the one that fails silently.

1. **The base cannot be diffed against** — absent, all zeros, missing from the
   clone, or no longer an ancestor after a force push: **every zone**. A run
   that plans too much is recoverable; one that silently plans nothing is not.
2. **A shared path changed** — `terraform/`, `policy/`, `tools/`, `Makefile`,
   `.github/workflows/`: **every zone**. A change to the rendering logic moves
   records in zones whose YAML nobody touched.
3. Otherwise: the zones under `zones/<z>/` that the diff names.
4. **A `zone.yaml` was deleted**: the script fails. See *Removing a zone*.

Locally, `make changed-zones` shows what the last commit would fan out to.

## The required status check is `gate`

Matrix jobs are named for their zone — `plan (matt-ffffff.com)` — so the set of
job names changes every time a zone is added, and none of them can be pinned in
branch protection. `gate` has a fixed name and is the one to require.

It runs `if: always()`, so it can never be skipped. That matters: GitHub counts
a *skipped* required check as satisfied, so a gate that skipped itself would
wave through exactly what it exists to stop. For the same reason the pass/fail
decision is made inside a step rather than in the job's `if:`.

`plan` being skipped is only accepted when `discover` succeeded and reported no
changed zones, or when the pull request came from a fork. Any other skip is
treated as a failure, because it is indistinguishable from `discover` having
died before writing its outputs.

## A superseded apply shows as cancelled

Each apply job takes `concurrency: dns-<zone>`, which `reconcile` shares, so one
zone is never written by two runs at once. `cancel-in-progress: false` protects
the job that is *running* — it does not protect one that is *queued*. Merge
three changes to one zone in quick succession and the middle run is dropped and
reported as cancelled, not failed.

That is the intended behaviour: Terraform converges on the latest commit, so the
end state is the same. A cancelled apply here means "something newer went
first", not "something broke".

## Fork pull requests cannot plan

A `pull_request` from a fork gets a read-only token and no secrets, which no
`permissions:` block can widen. That removes both the Cloudflare token and the
OIDC token, so `plan` is skipped and `gate` says so. `check` still runs, because
it needs no credentials.

This is live behaviour, not a hypothesis: the repository is public, so anyone
can fork it and open a pull request. What they get is `check` -- the full
layout, policy and fixture suite, which needs no credentials -- and a `gate`
that passes with a warning saying no plan was made. They cannot reach
Cloudflare, cannot reach the state, and cannot make the workflow post anything.

To give a fork a real plan you would split the untrusted half (build plan
output as an artifact, no secrets) from a trusted `workflow_run` that posts it.
Do not reach for `pull_request_target`.

## Removing a zone

`changed-zones.sh` refuses a commit that deletes a `zone.yaml`, because nothing
downstream would handle it: no job would be created for the zone, its state file
would be orphaned, and every record it owns would stay live in Cloudflare with
nothing describing it.

Removing a zone is manual and deliberate:

1. `make plan ZONE=<zone>` and read it.
2. `terraform -chdir=terraform destroy -var zone=<zone>`, if the records really
   are meant to go. Check the delegation first — if the zone is still delegated
   to Cloudflare, this takes it off the internet.
3. Delete the blob `zones/<zone>.tfstate`.
4. Delete `zones/<zone>/` and its CODEOWNERS lines, in a pull request of its
   own.

## Setting it up

### Azure, for the state

One storage account, one container, one blob per zone, and **two user-assigned
managed identities** -- one per environment, so the identity that may only read
a plan is not the identity that may write DNS.

Shared-key access is switched off on the account, so Entra is the only way in
and every identity needs data-plane RBAC. Control-plane Owner does not grant it:
that is the step people miss.

```bash
REPO=matt-FFFFFF/dns-operations
RG=rg-dns-operations
ACCOUNT=<globally unique, 3-24 lowercase chars>
LOC=uksouth

az provider register --namespace Microsoft.Storage --wait   # "SubscriptionNotFound" if you skip this

az group create --name "$RG" --location "$LOC"
az storage account create --name "$ACCOUNT" --resource-group "$RG" --location "$LOC" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false --https-only true

# container-rm, not `az storage container create`: the latter is a data-plane
# call, and with shared keys off you have no data-plane rights until the role
# assignment below exists. Chicken, egg.
az storage container-rm create --storage-account "$ACCOUNT" -g "$RG" --name dns-operations

az identity create --name id-dns-operations-plan  --resource-group "$RG" --location "$LOC"
az identity create --name id-dns-operations-apply --resource-group "$RG" --location "$LOC"
```

Data-plane roles, scoped to the container rather than the account or the
subscription:

```bash
SCOPE=$(az storage account show -n "$ACCOUNT" -g "$RG" --query id -o tsv)/blobServices/default/containers/dns-operations

for id in plan apply; do
  az role assignment create \
    --assignee-object-id "$(az identity show -n id-dns-operations-$id -g "$RG" --query principalId -o tsv)" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "$SCOPE"
done
```

Both identities get **Contributor**, not Reader. `terraform plan` takes a blob
lease to lock the state, which is a write; a read-only identity fails on the
lock, not on the plan. A human who only needs to look gets
`Storage Blob Data Reader` instead.

**Two** federated credentials, one per identity, because the OIDC subject
carries the environment name. A single credential authenticates half the
pipeline and leaves the other half failing with an opaque token-exchange error.

Repositories created after 15 July 2026 use GitHub's **immutable** subject
format, which identifies the owner and repository by id as well as by name, so
a rename cannot silently hand the credential to somebody else:

```
repo:<owner>@<owner_id>/<repo>@<repository_id>:environment:<environment>
```

```bash
IDS=$(gh api "repos/$REPO" --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"')
ISSUER=https://token.actions.githubusercontent.com
AUD=api://AzureADTokenExchange

az identity federated-credential create --name github-plan \
  --identity-name id-dns-operations-plan -g "$RG" \
  --issuer "$ISSUER" --subject "repo:${IDS}:environment:plan" --audiences "$AUD"

az identity federated-credential create --name github-production \
  --identity-name id-dns-operations-apply -g "$RG" \
  --issuer "$ISSUER" --subject "repo:${IDS}:environment:production" --audiences "$AUD"
```

Note the asymmetry: the identity is called `apply`, the environment it
federates to is called `production`. The environment name is what appears in
the token, so that is what the subject must say.

Then fill in `terraform/backend/azurerm.hcl` with `$RG` and `$ACCOUNT`.

### GitHub, for the credentials

Two environments. `plan` has no reviewers, because a pull request that has to
wait for a human before it can even show a plan teaches everybody to click
approve. `production` has reviewers and is restricted to `main`.

```bash
gh api --method PUT "repos/$REPO/environments/plan"

gh api --method PUT "repos/$REPO/environments/production" --input - <<JSON
{
  "reviewers": [{"type": "User", "id": $(gh api user --jq .id)}],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
JSON

TENANT=$(az account show --query tenantId -o tsv)
SUB=$(az account show --query id -o tsv)

# Each environment gets its own identity's client id. This is the whole point
# of two identities: the plan environment cannot assume the apply one.
gh variable set ARM_CLIENT_ID --env plan --repo "$REPO" \
  --body "$(az identity show -n id-dns-operations-plan -g "$RG" --query clientId -o tsv)"
gh variable set ARM_CLIENT_ID --env production --repo "$REPO" \
  --body "$(az identity show -n id-dns-operations-apply -g "$RG" --query clientId -o tsv)"

for env in plan production; do
  gh variable set ARM_TENANT_ID       --env "$env" --repo "$REPO" --body "$TENANT"
  gh variable set ARM_SUBSCRIPTION_ID --env "$env" --repo "$REPO" --body "$SUB"
done

# The Cloudflare token. Read it from somewhere; do not paste it into a shell
# that keeps history.
gh secret set CLOUDFLARE_API_TOKEN --env plan       --repo "$REPO"
gh secret set CLOUDFLARE_API_TOKEN --env production --repo "$REPO"
```

### What enforces what

This repository is **public**, which is what makes the enforcement free:
required reviewers on an environment, branch protection and required status
checks are all paid features on a private repository. That is the whole reason
it is public, so think twice before making it private again -- doing so silently
removes every gate below.

| gate | what it stops |
| --- | --- |
| `gate` as a required status check in the `main` ruleset | a merge while `check`, `discover` or any zone's `plan` is failing |
| required reviewer on `production` | an apply running without a human saying yes |
| deployment branch policy on `production` | an apply from any branch but `main` |

Two settings are deliberately weaker than the design wants, both because there
is one person here:

- `required_approving_review_count: 0` and `require_code_owner_reviews: false`.
  GitHub does not let anyone approve their own pull request, so requiring an
  approval would lock the only owner out of the repository. Turning both on is
  the first thing to do when a second person arrives, and it is what gives
  CODEOWNERS any force at all.
- The ruleset has **no bypass actors**, so the required check applies to the
  owner too. Under classic protection with `enforce_admins: false` it did not,
  and a failing `gate` left a pull request mergeable. See
  [branch-protection.md](branch-protection.md).

Both environments hold the same token to begin with. Narrow the `plan` one to
`Zone:Read` + `Zone:DNS:Read` when convenient — no workflow changes needed.

Until `ARM_CLIENT_ID` and the rest are set, every Terraform job fails in
`.github/actions/tf-init` and names what is missing. That is deliberate: a job
that cannot reach Cloudflare must be red, not a green tick for a check it never
made.
