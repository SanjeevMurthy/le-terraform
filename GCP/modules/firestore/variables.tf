variable "location_id" {
  description = "Firestore location. Use a region like \"us-central1\" (cheapest) or a multi-region like \"nam5\". THIS CANNOT BE CHANGED after creation."
  type        = string
  default     = "us-central1"
}

variable "deletion_policy" {
  description = "Set to DELETE so \"terraform destroy\" can actually remove the database. Use ABANDON in production."
  type        = string
  default     = "DELETE"
}
