output "database_name" {
  description = "Firestore database name (always \"(default)\" for the primary database)."
  value       = google_firestore_database.default.name
}

output "location_id" {
  description = "Where the Firestore data physically lives."
  value       = google_firestore_database.default.location_id
}
