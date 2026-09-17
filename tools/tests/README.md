# Fixture zones

Each directory under `zones/` breaks one thing on purpose. `make test-fixtures`
runs `dnsctl validate` over all of them and diffs the result against
`expected.txt`.

A rule that is never seen to fire is a rule nobody knows is broken, and the
messages are half the point: a rule that rejects a change without explaining
which change to make instead just gets worked around.

To add a rule: add a fixture that violates it, run

    make test-fixtures-update

read the diff, and commit it.
