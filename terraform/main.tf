# One zone per root module invocation, and so one state file per zone.
#
# The zone is chosen by `-var zone=<name>` and the state it is written to by
# `-backend-config="key=zones/<name>.tfstate"` at init. The two must agree:
# pointing this at one zone while holding another zone's state would plan to
# delete every record in both. `make plan ZONE=x` and the CI workflows derive
# both from the same string so they cannot drift apart.

locals {
  zones_root = coalesce(var.zones_dir, "${path.module}/../zones")
  zone_dir   = "${local.zones_root}/${var.zone}"

  # No guard needed: file() fails with the exact path it could not find, which
  # is a better error than anything that could be written here.
  zone_cfg = yamldecode(file("${local.zone_dir}/zone.yaml"))

  # A zone whose id is not written down has to be found by name.
  zone_id = try(local.zone_cfg.zone_id, null) != null ? local.zone_cfg.zone_id : data.cloudflare_zone.lookup[0].id
}

data "cloudflare_zone" "lookup" {
  count = try(local.zone_cfg.zone_id, null) == null ? 1 : 0

  filter = {
    name    = var.zone
    account = try(local.zone_cfg.account_id, null) == null ? null : { id = local.zone_cfg.account_id }
  }
}

module "zone" {
  source = "./modules/zone"

  zone_name = var.zone
  zone_dir  = local.zone_dir
  zone_id   = local.zone_id
}
