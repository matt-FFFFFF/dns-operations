variable "zone_name" {
  description = "The zone apex, e.g. matt-ffffff.com. Also the directory name under zones/."
  type        = string
}

variable "zone_dir" {
  description = "Path to the directory holding zone.yaml, apex/, validations/ and services/."
  type        = string
}
