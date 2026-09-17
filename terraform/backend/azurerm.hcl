# The half of the backend configuration that is the same for every zone. The
# other half is the per-zone key, passed as a second -backend-config at init.
#
# ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID come from the environment;
# docs/ci.md has the az commands that created all of this.
resource_group_name  = "rg-dns-operations"
storage_account_name = "stdnsopsa99e1fdc6e"
container_name       = "dns-operations"

# Authenticate to the blob itself with the Entra identity rather than a storage
# account key. Not optional here in two senses: the account is created with
# allowSharedKeyAccess = false, so there is no key to fall back to, and without
# this the backend would try to fetch one and fail with an opaque authorization
# error rather than a missing-setting one.
#
# How that identity is obtained is deliberately not set here. CI sets
# ARM_USE_OIDC=true and the token comes from GitHub; locally it comes from
# `az login`. Pinning use_oidc in this file would break the second case.
use_azuread_auth = true
