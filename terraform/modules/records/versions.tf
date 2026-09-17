# No provider and no resources. This module is arithmetic on files, which is
# why it can be used as a root module and evaluated without credentials:
#
#   terraform -chdir=terraform/modules/records init -backend=false
#   terraform -chdir=terraform/modules/records console \
#     -var zone_name=matt-ffffff.com -var zone_dir=../../../zones/matt-ffffff.com
terraform {
  required_version = ">= 1.9.0"
}
