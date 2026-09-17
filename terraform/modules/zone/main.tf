# What the files say.
module "records" {
  source = "../records"

  zone_name = var.zone_name
  zone_dir  = var.zone_dir
}

# What Cloudflare is told.
resource "cloudflare_dns_record" "this" {
  for_each = module.records.records

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.provider_content
  ttl     = each.value.ttl
  proxied = each.value.proxied

  # Unused by every type except MX, SRV and URI, where the provider requires it.
  priority = each.value.priority

  # Names the file to change. Someone who finds this record in the Cloudflare
  # dashboard should not have to guess where it came from, and should not edit
  # it there.
  comment = "${var.record_comment_prefix}: ${each.value.source}"
}
