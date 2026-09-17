output "zone" {
  description = "The zone this state file owns, its Cloudflare id and how many records this repository holds in it."
  value = {
    zone_name    = module.zone.zone_name
    zone_id      = module.zone.zone_id
    record_count = length(module.zone.record_keys)
    services     = module.zone.services
  }
}

output "record_keys" {
  description = "Every managed record in this zone, as \"<name>|<TYPE>|<content>\"."
  value       = module.zone.record_keys
}
