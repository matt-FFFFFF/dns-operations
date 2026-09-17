output "zone_name" {
  description = "The zone apex."
  value       = var.zone_name
}

output "zone_id" {
  description = "The Cloudflare zone id the records were written to."
  value       = var.zone_id
}

output "record_keys" {
  description = "Every managed record as \"<name>|<TYPE>|<content>\", sorted."
  value       = module.records.record_keys
}

output "services" {
  description = "Service namespaces, their owning team and their delegation state."
  value       = module.records.services
}
