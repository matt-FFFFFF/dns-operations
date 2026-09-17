# AGENTS.md

DNS for `matt-ffffff.com`, held in Cloudflare, described as YAML and applied with
Terraform. [README.md](README.md) explains the layout and why it is shaped that
way; read it first. This file is the part that is easy to get wrong.

## Commands

```
make check         # everything CI runs. Run this before saying you are done.
make render        # every record the tree produces
make validate      # parse and check the tree only
make lint          # actionlint, shellcheck, pinact
make test          # policy unit tests
make test-fixtures # the validator's own tests
make test-changed-zones  # the CI fan-out rules
make test-supersede      # which waiting runs may be cancelled
make changed-zones # which zones the last commit would plan
make plan ZONE=x   # needs credentials
```

Tools come from `mise.toml`; run `mise install`, and `mise exec -- make check`
if mise is not activated in the shell. `uv` fetches PyYAML itself; there is
nothing to install for `dnsctl`.

**Every Terraform command names a zone**, because state is one blob per zone:
`-var zone=<z>` and a matching `-backend-config="key=zones/<z>.tfstate"`. The
two must always be the same string. Pointing the config at one zone while
holding another zone's state plans to delete every record in both.

`plan`, `apply`, `drift` and `import-blocks` need `CLOUDFLARE_API_TOKEN`.
Locally the token lives in `terraform/providers_override.tf`, which overrides
`providers.tf` and is excluded by `.gitignore` (`*_override.tf`). `dnsctl` reads
the environment variable instead, so export it as well when running the tool
directly. **Never write a credential into a file that is not already ignored,
and never echo one into a summary.**

## Ask before doing

- **`terraform apply`.** This is production DNS: a wrong apply takes down mail
  and the website together. Plan, show the plan, ask.
- **Deleting a record**, in Cloudflare or in the YAML. `make drift` reports
  unmanaged records; it does not remove them, on purpose.
- **Anything at the registrar** -- nameservers, DS records. See the DNSSEC
  ordering in [docs/adoption.md](docs/adoption.md); getting it backwards makes
  the whole domain bogus for the length of the DS record's TTL.

Reading is free: `plan`, `render`, `verify`, `drift` and `import-blocks` are all
read-only.

## Invariants

**The layout is implemented twice.** `terraform/modules/records/locals.tf` is
what applies. `tools/dnsctl.py` is what validates and what compares against the
live zone. They are allowed to be two implementations; they are not allowed to
disagree. Change one, change the other, and `make render-diff` will tell you if
you forgot.

**A record's identity is `name|TYPE|content`, with `content` as written.** That
string is the Terraform map key, the `dnsctl render --keys` output, and the
import-block key. `provider_content` is a separate field holding the wire form.
Never key anything on `provider_content`: TXT values differ between the two, and
using the wire form as the key would silently re-create every TXT record.

**Namespaces come from paths. No file declares one.** A service's namespace is
its directory name. `apex/` and `validations/` are relative to the zone apex.
There is no fully qualified form anywhere in the YAML. This is what stops a team
writing a record outside its own namespace, so do not add a `namespace:` or a
`zone:` field to a record file to make something convenient.

**Validation files have no `type:` field.** That is load-bearing, not an
oversight: it is why no rule has to reject an MX or NS record there. If you find
yourself adding a rule to reject a record type in `validations/`, you have
probably just added a `type:` field somewhere you should not have.

**`apex/`, `validations/` and `services/` are siblings.** None may contain
another. CODEOWNERS applies the last matching pattern, so nesting them would make
the order of the lines decide who can approve a path, and a reordering would
change permissions with nothing to show for it in the diff.

**`policy/layout.rego` reads what `dnsctl build` writes.** The keys of that
document -- `services`, `validations`, `files`, `records`, `today`, and the
fields on each -- are a contract between the two. Change the shape in one and the
rules in the other stop matching anything, which fails open and silently.

## Traps, all of them found the hard way

**TXT content must reach the provider quoted.** Cloudflare requires the
zone-file form: each string in double quotes, split into 255-character strings
once longer than one. The provider normalises nothing in either direction, and
the API returns the quoted form. Unquoted content produces a record the
dashboard marks invalid ([#6354][cf6354]) and a plan that never converges.
`local.txt_wire` in `modules/records/locals.tf` does the quoting, escaping and
chunking; `_api_content()` in `dnsctl.py` undoes it when reading the API. The
YAML stays unquoted. Both sides must change together.

**Import blocks must use `for_each`.** Repeated `import` blocks aimed at
instances of the same resource inside a module apply only the first and ignore
the rest with no warning: 15 blocks planned as `1 to import, 14 to add`, which
would have duplicated the whole zone. The `for_each` form planned as `15 to
import, 0 to add`. Verified on Terraform 1.16.0. `dnsctl import-blocks` emits
the working form; do not "tidy" it into one block per record.

**The Cloudflare API does not put `zone_id` on a record.** An import id is
`<zone id>/<record id>` and only half of it is in the record, which is why
`live_records()` returns both.

**`not x` in Rego does not fire when `x` is null.** Only `false` and undefined
are falsy, so a key that is present and null satisfies neither `x` nor `not x`,
and the rule quietly never fires -- which is how `vendor`, `purpose` and
`expires` were unenforced until a test caught it. Use `missing(obj, field)`.
Comparisons have the mirror problem: `null < "2026-01-01"` is true, because null
sorts below every string, so guard expiry rules with `is_string`.

**A proxied record must have `ttl = 1`.** The provider hard-errors on anything
else, and only on create, not update. The module forces it; the validator rejects
a file that sets both.

**`cmd && thing || true` swallows a failure of `thing`, not just of `cmd`.** That
is how `make fmt-check` silently passed on unformatted Rego. Use
`if command -v x; then x ...; fi`.

[cf6354]: https://github.com/cloudflare/terraform-provider-cloudflare/issues/6354

## Adding a rule

A rule needs three things, and `make check` will not pass without them:

1. The check itself, in `tools/dnsctl.py` (parse and shape errors, and anything
   needing CODEOWNERS or the filesystem) or `policy/layout.rego` (what a record
   may be). Prefer making the wrong thing unwritable over detecting it.
2. A test that watches it fire -- `policy/layout_test.rego` for Rego, plus a
   fixture zone under `tools/tests/zones/` for `dnsctl`. Test the opposite too: a
   rule that fires on everything is as broken as one that fires on nothing.
3. `make test-fixtures-update`, then read the diff before committing it.

Write the message as an instruction, not a refusal. A rule that blocks a change
without saying what to do instead gets worked around, usually by someone editing
the Cloudflare dashboard, which nothing here can see.

## Style

Terraform is `terraform fmt`; Rego is `opa fmt`; Python is `ruff` clean and has
no third-party dependency beyond PyYAML, which `uv` resolves from the script
header. Comments explain why, not what -- the file above you is the example to
follow. Keep `dnsctl.py` a single file with no package: it has to run from a
checkout with nothing installed.
