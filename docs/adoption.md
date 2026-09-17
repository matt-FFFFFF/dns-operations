# Adopting a zone that already exists

Terraform creates what it is told about and deletes what it used to be told
about. It has no opinion at all about a record it has never seen. So the first
apply against a live zone will either adopt the records that are already there
or create duplicates of them. Which one happens is decided before the apply, not
during it.

## 1. Describe what is actually there

Export the zone from the Cloudflare dashboard (DNS → Records → Export) and write
it into `zones/<zone>/` as apex, validation and service files. Do not tidy while
you transcribe. The goal of this step is a repository that describes the zone as
it is, so that the first plan is empty. Improvements are a second commit, with
their own plan showing exactly what they change.

    make validate
    make render        # every record the tree produces

Compare that list against the export line by line.

## 2. Pair each record with its Cloudflare id

Terraform addresses a record by what it is -- name, type, value. Cloudflare
addresses it by a random id. Pair them up:

    export CLOUDFLARE_API_TOKEN=...          # Zone:DNS:Read is enough here
    ./tools/dnsctl.py import-blocks --out terraform/imports.tf

**This step is not optional and the file is not in the repository.**
`terraform/imports.tf` is a list of Cloudflare record ids, so `.gitignore`
excludes it: this repository is public and those ids have no business in it.
Without the file the first apply *creates* every record rather than adopting
it, against a zone that already holds them. Regenerate it here, every time,
for every zone being adopted.

Anything the repository describes but Cloudflare does not hold is reported on
stderr: those will be created rather than adopted, which is usually a sign of a
transcription error rather than a decision.

The generated file is one `import` block with `for_each`, not one block per
record. That is not a style choice. Repeated `import` blocks aimed at instances
of the same resource inside a module were observed to apply only the first and
ignore the rest without a warning: fifteen blocks planned as `1 to import, 14 to
add`, which would have created a second copy of the entire zone. The `for_each`
form planned as `15 to import, 0 to add`. Checked against Terraform 1.16.0.

## 3. Confirm the plan changes no DNS data

    make plan ZONE=matt-ffffff.com

Expect `N to import, 0 to add, N to change, 0 to destroy`. The changes are real
but they are all the same change: every record gains a `comment` naming the file
it came from. Confirm that, rather than taking it on trust:

    terraform -chdir=terraform init -input=false -reconfigure \
      -backend-config=backend/azurerm.hcl \
      -backend-config="key=zones/matt-ffffff.com.tfstate"
    terraform -chdir=terraform plan -input=false -var zone=matt-ffffff.com -out=tfplan
    terraform -chdir=terraform show -json tfplan | jq -r '
      [.resource_changes[]
       | . as $r | ($r.change.before // {}) as $b | ($r.change.after // {}) as $a
       | [ $a | to_entries[] | select(.value != $b[.key]) | .key ] | join(",")
      ] | group_by(.) | map({changed_fields: .[0], count: length})'

`[{"changed_fields": "comment", "count": N}]` means no DNS data moves. Anything
else means the repository does not yet describe the zone, and the thing to fix
is the YAML, not the plan.

## 4. Apply, then delete the import blocks

    make apply ZONE=matt-ffffff.com
    # then drop this zone's entry from terraform/imports.tf, and the file
    # itself once the last zone has been adopted

## 5. Find what the repository does not manage

    make drift

Terraform will never tell you about a record added by hand in the dashboard,
because it does not delete what it was never told about. This will. Everything
it lists is either something to write into the repository or something to delete
in Cloudflare; leaving it in neither state is how a zone drifts back to being
edited in a web UI.

---

# Moving a zone to Cloudflare

Only relevant for a zone that is not on Cloudflare yet. `matt-ffffff.com` already
is.

**If the zone is DNSSEC-signed, changing the nameservers first breaks the entire
domain.** Validating resolvers still have the old DS record, which no longer
matches the keys the new nameservers publish, so every name in the zone goes
bogus: web and mail stop together, and they stop for the length of the DS
record's TTL rather than for the length of the mistake.

The order is not negotiable:

1. Remove the DS record at the registrar.
2. Wait for the DS record's TTL to expire. Check with `dig DS <zone>` until it
   returns nothing.
3. Change the nameservers.
4. Let Cloudflare sign the zone and publish the new DS record at the registrar.

`make verify` checks both halves of this: that the live delegation matches the
`nameservers` list in `zone.yaml`, and that the DS record's presence matches the
`dnssec` field. Update `zone.yaml` after each step, never before.
