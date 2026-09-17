# The half of the backend configuration that is the same for every zone. The
# other half is the per-zone key, passed as a second -backend-config at init.
#
# REPLACE-ME below, plus ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID in
# the environment. docs/ci.md has the az commands that create all of it.
resource_group_name  = "rg-tfstate"
storage_account_name = "REPLACE-ME"
container_name       = "dns-operations"

# Authenticate to the blob itself with the Entra identity rather than a storage
# account key. Required, not optional: without it the backend tries to fetch an
# account key, which an OIDC identity holding only Storage Blob Data Contributor
# cannot do, and the failure reads as an opaque authorization error rather than
# a missing setting.
#
# How that identity is obtained is deliberately not set here. CI sets
# ARM_USE_OIDC=true and the token comes from GitHub; locally it comes from
# `az login`. Pinning use_oidc in this file would break the second case.
use_azuread_auth = true
