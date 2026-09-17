variable "zone_name" {
  description = "The zone apex, e.g. matt-ffffff.com. Also the directory name under zones/."
  type        = string
}

variable "zone_dir" {
  description = "Path to the directory holding zone.yaml, apex/, validations/ and services/."
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone id."
  type        = string
}

variable "record_comment_prefix" {
  description = <<-EOT
    Prefix for the comment written onto every managed record. The comment names
    the file the record came from, so someone looking at the Cloudflare
    dashboard can find the file to change instead of editing in the dashboard.
  EOT
  type        = string
  default     = "dns-operations"
}
