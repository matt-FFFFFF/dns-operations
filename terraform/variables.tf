variable "zone" {
  description = <<-EOT
    The zone directory under zones/ that this state file owns. One zone per
    state file: the blob key is derived from this name at init time, so a
    plan for one zone never touches another zone's state.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.zone))
    error_message = "zone must be a zone directory name, e.g. matt-ffffff.com."
  }
}

variable "zones_dir" {
  description = <<-EOT
    Path to the directory holding one subdirectory per zone. Only overridden by
    tests; the default is the zones/ directory of this repository.
  EOT
  type        = string
  default     = null
}
