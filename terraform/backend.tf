# State lives in Azure Blob Storage, one blob per zone.
#
# The block is empty on purpose. Everything is supplied at init, because the
# blob key is what makes the state per-zone:
#
#   terraform -chdir=terraform init -input=false -reconfigure \
#     -backend-config=backend/azurerm.hcl \
#     -backend-config="key=zones/<zone>.tfstate"
#
# -reconfigure is what lets one working directory move between zones. Without
# it Terraform sees the key change and offers to migrate the previous zone's
# state into the new key, which would put two zones in one blob.
#
# `make check` and `terraform validate` run with -backend=false and so need
# none of this: the layout can be checked without credentials.
terraform {
  backend "azurerm" {}
}
