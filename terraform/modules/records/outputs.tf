output "records" {
  description = "Every record the zone directory produces, keyed by \"<name>|<TYPE>|<content>\"."
  value       = local.records
}

output "record_keys" {
  description = <<-EOT
    The keys of `records`, sorted. This is the same set of strings that
    `dnsctl render --keys` prints; `make render-diff` diffs the two, so the two
    implementations of the layout cannot drift apart unnoticed.
  EOT
  value       = sort(keys(local.records))
}

output "services" {
  description = "Service namespaces, their owning team and their delegation state."
  value = {
    for dir, svc in local.services : "${dir}.${var.zone_name}" => {
      owner      = try(svc.owner, null)
      expires    = try(svc.expires, null)
      delegated  = try(svc.delegation.type, null) == "external"
      delegation = try(svc.delegation, null)
    }
  }
}
