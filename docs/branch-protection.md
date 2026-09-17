# Branch protection

`.github/CODEOWNERS` is a text file. It becomes a control only when the default
branch is configured to obey it. Without the settings below it is a document
that looks like a control, which is worse than having neither, because people
stop checking the thing they believe is already checked.

Set these on a ruleset targeting `main`:

| Setting | Why |
| --- | --- |
| Require a pull request before merging | Nothing reaches `main` without review. |
| Require review from Code Owners | This is the line that makes CODEOWNERS do anything at all. |
| Dismiss stale pull request approvals when new commits are pushed | Without it, a change is approved, then rewritten, and merges on the old approval. |
| Require status checks to pass: `gate` | The policy gate. See `.github/workflows/validate.yml`. |
| Require branches to be up to date before merging | Two changes that are each fine can be wrong together. A CNAME added in one and a TXT record at the same name added in the other pass separately and break the zone once merged. |
| Do not allow bypassing the above settings | An exemption for administrators is an exemption for everyone who can become one. |
| Block force pushes | The history is the audit trail. |

## Everyone in CODEOWNERS needs write access

GitHub does not count an approval from someone without write access to the
repository, and it will not request a review from them either. The approver
group in the design includes the CEO and the COO. Confirm both have write access
and will review in GitHub before anything depends on them. If that is not
realistic, record executive approval somewhere else and let CODEOWNERS name the
two heads of department.

## One approver, not all of them

CODEOWNERS is OR logic: any one member of the critical-approvers group
merges a change to the apex. That is the intention, but be clear about it. If a
change to the mail records must have two approvals, CODEOWNERS cannot express
that. Two options:

- Set **Require approvals: 2** on the ruleset. This applies to every change in
  the repository, including a team editing its own subdomain.
- Use the `production` environment on `.github/workflows/apply.yml` and add
  required reviewers there. The merge takes one approval; the apply takes
  another, from a list that does not have to overlap with repository write
  access. This is also where an approval from somebody who will never use
  GitHub's review interface can live.

## Why the required check is `gate` and not `plan`

`plan` is a matrix job with one leg per changed zone, so its jobs are named for
their zone -- `plan (matt-ffffff.com)`. The set of names changes every time a
zone is added or removed, and a name that is not present cannot be required.

`gate` runs after `check`, `discover` and `plan`, has a fixed name, and fails
unless each of them succeeded or was skipped for a reason `discover` can
account for. Requiring `plan` legs individually would silently stop protecting
any zone added afterwards. See [ci.md](ci.md).

## What is actually set, today

`main` is protected by a **repository ruleset**, not by classic branch
protection. One mechanism, so there is one place to look:

```bash
gh api repos/matt-FFFFFF/dns-operations/rules/branches/main
```

| rule | effect |
| --- | --- |
| `required_status_checks` -> `gate` | nothing merges while the pipeline disagrees, and `strict` means the branch must be up to date with `main` first |
| `pull_request` | no direct pushes to `main`; squash or rebase only |
| `required_linear_history` | no merge commits |
| `non_fast_forward` | no force-pushing `main` |
| `deletion` | `main` cannot be deleted |

`bypass_actors` is empty. Nobody bypasses this, including the owner -- which is
the point. With classic protection and `enforce_admins: false` the required
check did not apply to the repository owner at all: a failing `gate` left the
pull request `UNSTABLE` (mergeable, with a failing check) rather than
`BLOCKED`. The gate existed and enforced nothing. Verified both ways against a
live pull request before the ruleset replaced it.

### Zero approvals, and what to change when there are two of you

`required_approving_review_count` is **0** and `require_code_owner_review` is
**false**. That is not the design; it is what a one-person repository can have,
because GitHub refuses to let anyone approve their own pull request. Until there
is a second person, `gate` is the control and CODEOWNERS is documentation.

When a second person arrives, raise the count to 1 and turn on code-owner
review in the same ruleset. That single change is what gives every line of
`.github/CODEOWNERS` its force.

### No bypass means no bypass

There is no escape hatch, on purpose. If `gate` fails for a reason unrelated to
the change -- a broken runner, an expired credential -- the fix is to make
`gate` pass, not to route around it. The only lever is editing the ruleset
itself, which is an auditable act rather than a quiet one.

That cuts both ways, and it bit once already: while `ARM_*` was unset, `plan`
could not run, so `gate` could not pass, so nothing could merge at all. The
pipeline was behaving correctly and the repository was still stuck. If you hit
that again, the answer is usually that CI is missing something it needs, not
that the rule is wrong.
