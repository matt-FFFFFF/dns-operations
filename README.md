# dns-operations

DNS for `matt-ffffff.com`, held in Cloudflare, described here.

This is a trial run of a production DNS design, on a zone small enough to be
safe and real enough to be a test: `matt-ffffff.com` carries live mail, a real
DKIM selector and a real delegation to another provider. Anything the design
gets wrong shows up here before it reaches a zone that matters.

Working on the tooling rather than the records? [AGENTS.md](AGENTS.md) has the
invariants and the traps.

## The idea

Every change has exactly one correct location, and the location is the
permission. Nobody decides where a record goes, and no reviewer decides whether a
change is important: the path already says both.

```
zones/
  matt-ffffff.com/
    zone.yaml                    zone id, DNSSEC state, nameservers, default TTLs
    apex/                        answers at matt-ffffff.com or directly below it
      website.yaml               the apex A records and www
      icloud-mail.yaml           MX, SPF, the DKIM selector, _dmarc
      microsoft-365.yaml         autodiscover
    validations/                 the only route to the apex for everyone else
      apple.yaml                 one file per vendor, not per team
    services/                    one directory per team subdomain
      home/
        service.yaml             owner, expiry date, delegation
        records.yaml             names relative to home.matt-ffffff.com
      email/
        service.yaml             delegated to Azure DNS -- no records.yaml
policy/                          what a record may be
terraform/                       how it reaches Cloudflare
tools/dnsctl.py                  what refuses
```

`apex/`, `validations/` and `services/` are siblings. None is inside another, so
no CODEOWNERS pattern below can overlap another and the order of the lines cannot
change who approves a path.

## Where a change goes

| Change | Location | Approved by |
| --- | --- | --- |
| Mail, CAA, the website, anything else answering at the apex | `apex/<service>.yaml` | Critical approvers |
| A TXT or CNAME record proving the domain to a vendor | `validations/<vendor>.yaml` | Service approvers |
| Creating, changing or removing a team subdomain | `services/<name>/service.yaml` | Service approvers |
| Ordinary records inside a subdomain that exists | `services/<name>/records.yaml` | The owning team |
| Zone settings, modules, policy, CODEOWNERS | `zone.yaml`, `terraform/`, `policy/`, `.github/` | Critical approvers |

Creating a service needs both: a service approver for `service.yaml`, and a
critical approver for the one CODEOWNERS line that hands the team merge rights.
That falls out of the structure rather than being an extra rule -- you cannot
hand out merge rights without editing the file that hands out merge rights.
Changing or removing a service that already exists needs only a service approver.

CODEOWNERS does nothing at all without branch protection. See
[docs/branch-protection.md](docs/branch-protection.md).

## Adding a record

**A record for your own subdomain** -- `services/<you>/records.yaml`. Names are
relative to your namespace and there is no fully qualified form, so what you
write cannot land outside it. `"@"` is the namespace itself.

```yaml
records:
  - name: docs                   # docs.home.matt-ffffff.com
    type: CNAME
    values: ["example-docs.pages.dev"]
    proxied: true
```

Types are an allowlist: `A`, `AAAA`, `CNAME`, `TXT`. Not a denylist, because a
denylist permits every type nobody has thought about, and those are the dangerous
ones. `HTTPS` and `SVCB` carry ALPN, port and ECH parameters that change how a
browser connects. `TLSA` can stop inbound mail from every DANE sender. `SRV`
moves service discovery somewhere else.

**Proving the domain to a vendor** -- one file per vendor in `validations/`.

```yaml
vendor: hubspot
requested_by: marketing
purpose: "Domain verification for the HubSpot marketing hub"
expires: 2027-03-01                  # mandatory

txt:
  "@": ["hubspot-domain-verification=..."]
cname:
  _hubspot: verify.hubspot.com.      # one name, one target
```

No `type:` field, so an MX or NS record has nowhere to be written and no rule has
to reject one. `txt` maps a name to a list and `cname` maps a name to a single
string, because a name may carry many TXT strings but only one CNAME.

`vendor`, `purpose` and `expires` are required. A record nobody can explain is a
record nobody will ever dare to delete, which is why such records survive for
years. One file per vendor means dropping HubSpot is `git rm hubspot.yaml`, not
an afternoon in the repository history.

**Delegating a subdomain to someone else** -- a property of the service, not a
record:

```yaml
owner: "@example/platform-engineering"
delegation:
  type: external
  nameservers: [ns1-03.azure-dns.com, ns2-03.azure-dns.net]
  expires: 2027-09-17                # mandatory
```

A delegated service must not have a `records.yaml`, and policy refuses one. Below
a delegation, resolvers follow the NS records and never read anything else this
zone publishes there, so those records would be YAML that looks maintained and
answers nothing. There is a live example of exactly that in this zone -- see
[the state of this zone](#the-state-of-this-zone) below.

## Running it

```
make help          # all targets
make check         # everything a pull request must pass
make render        # every record the tree produces
make verify        # ask the public DNS whether zone.yaml is still true
make drift         # ask Cloudflare what it holds that this repo does not
make plan          # every zone in turn
make plan ZONE=matt-ffffff.com
make apply ZONE=matt-ffffff.com
```

Each zone has its own Terraform state file, so every Terraform command names a
zone. `ZONE=` picks one; without it the target walks all of them in turn,
re-initialising the backend against each zone's state key as it goes.

Tools come from [mise](https://mise.jdx.dev/): `mise install` gets Terraform,
opa, uv and the linters at the versions `mise.toml` pins, and CI installs the
same file. `uv` fetches PyYAML itself; there is nothing to install for
`dnsctl`.

`plan`, `apply` and `drift` need a Cloudflare API token. Locally it goes in
`terraform/providers_override.tf`, which overrides the empty provider block in
`providers.tf` and is excluded by `.gitignore`. `dnsctl` reads the environment
instead, so export it too:

```
export CLOUDFLARE_API_TOKEN=...      # Zone:DNS:Edit, plus Zone:Zone:Read
                                     # while zone_id is null in zone.yaml
```

CI has neither file: the workflows read the token from the `plan` and
`production` GitHub environments, and reach Azure for state over OIDC. How that
is set up, and how a change fans out to one job per changed zone, is
[docs/ci.md](docs/ci.md).

Adopting a zone Cloudflare already serves is [docs/adoption.md](docs/adoption.md).

## What checks what

**`tools/dnsctl.py`** parses the tree with a YAML loader that refuses a duplicate
key. Most parsers accept one, keep the last and say nothing, so a second
`_hubspot:` deletes the first and the reviewer sees a diff that only adds a line.
It also rejects unknown keys, so `proxy: true` is an error rather than a setting
that silently does nothing.

**`policy/layout.rego`** decides what a record may be. CODEOWNERS matches paths,
but the interesting facts are types and names, and a team with write access to
its own `records.yaml` can write anything in it while touching only a path it
legitimately owns. `policy/layout_test.rego` has a test for each rule and for
each rule's opposite.

**`tools/tests/`** holds zones that break one thing each. `make test-fixtures`
checks that `dnsctl` still rejects all of them, with the messages it is supposed
to use. A rule that is never seen to fire is a rule nobody knows is broken.

**`make lint`** runs `actionlint` over the workflows, `shellcheck` over the
shell, and `pinact` to check every action is pinned to a commit rather than a
tag somebody else can move. `make test-changed-zones` builds a throwaway git
repository and checks the CI fan-out rules still hold -- which zones a commit
plans, and that deleting a zone is refused.

**`make render-diff`** diffs the two implementations of the layout --
`terraform/modules/records` and `tools/dnsctl.py` -- against each other. They are
allowed to be two implementations. They are not allowed to disagree.

**`make verify`** asks the public DNS whether the delegation and the DNSSEC state
still match `zone.yaml`. Both live at the registrar, outside Cloudflare and
outside this repository.

**`make drift`** asks Cloudflare what it holds that this repository does not.
Terraform will never report this: it does not delete what it was never told
about, so a record added by hand in the dashboard is invisible to a plan. The
nightly `drift` workflow runs this against every zone, and keeps one issue per
zone -- updated while the difference lasts, closed when the zone comes back.

### TXT records are quoted on the way out

Cloudflare requires TXT content in its zone-file form: each string in double
quotes, split into 255-character strings once it is longer than one. The provider
does neither. It sends what the configuration says and stores what the API
returns, and the API returns the quoted form, so unquoted `content` produces a
record the Cloudflare dashboard marks as invalid ([#6354][cf6354]) and a plan
that shows the same change every time it runs.

`terraform/modules/records` does the quoting, escaping and chunking at the point
the value is handed to the provider. The YAML stays unquoted, because a file that
says `["v=spf1 include:icloud.com ~all"]` is a file that says what it means, and
`dnsctl` undoes the same transformation when it reads the API.

[cf6354]: https://github.com/cloudflare/terraform-provider-cloudflare/issues/6354

## Two places this differs from the design document

**Dotted names in `apex/`.** The design says a name field holds one label, with a
dot allowed only in a TXT name. Real DKIM breaks that: iCloud, and every other
mail provider that rotates its own keys, publishes DKIM as a CNAME at a dotted
name such as `sig1._domainkey`. The one-label rule is enforced in `validations/`
and in `services/*/records.yaml`, where it does the work the design describes --
keeping a record inside the namespace it was written in. `apex/` is not
restricted, which matches the design's own Rego and its description of `apex/` as
the place for the record type this design did not foresee. Critical approvers own
those files.

**Dotted TXT names inside a service.** Permitted, because `_acme-challenge.docs`
is how a team gets a certificate for `docs.<their-namespace>`, and a dotted name
in a service file is inside that team's own namespace by construction.

## The state of this zone

Transcribed from the Cloudflare export on 17 September 2026 and checked against
the live API. **Not yet applied.** The plan is:

```
Plan: 15 to import, 0 to add, 15 to change, 0 to destroy
```

Every record is adopted rather than recreated, and the only field that changes on
any of them is `comment` -- the `dns-operations: <file>` marker that tells anyone
looking at the Cloudflare dashboard which file to edit instead. No DNS data
moves. `terraform/imports.tf` holds the pairing, keyed by zone; drop this
zone's entry once it has been applied, and the file when the last one goes.

Cloudflare holds 16 records this repository could manage. The sixteenth is
deliberately left out:

> `email.matt-ffffff.com TXT "ms-domain-verification=..."` sits in Cloudflare at
> the point where `email` is delegated to Azure DNS. Azure serves that record,
> plus an SPF record Cloudflare's copy does not have, and Azure's answer is the
> one the world gets. Cloudflare's copy is already stale and nothing would have
> said so. `make drift` reports it so it can be deleted at source.

Open, and worth deciding before this pattern is used anywhere that matters:

- `autodiscover.matt-ffffff.com` points at Microsoft 365 while the apex MX records
  point at iCloud, so it is answering for mailboxes that are not there. It is
  modelled as it is in `apex/microsoft-365.yaml`. If nothing uses a
  `@matt-ffffff.com` address with Outlook, delete the file.
- There is no CAA record. Adding one is a real change to who may issue
  certificates for the domain, not a transcription, so it is left out of the
  first commit on purpose. `apex/certificates.yaml` is where it goes.
- CODEOWNERS names one account on every line, because GitHub will not let
  anyone approve their own pull request and a one-person repository that
  required code-owner review would lock its owner out. `gate` is a required
  check and does block a merge; CODEOWNERS does not, yet. The three tiers are
  kept as structure -- see [docs/branch-protection.md](docs/branch-protection.md)
  for what to turn on when there is a second person. Point them at real teams,
  or swap them for the handles this repository actually
  has, before relying on the approval boundaries.
