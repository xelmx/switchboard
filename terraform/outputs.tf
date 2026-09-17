output "registry" {
  description = "Prefix for the image: <registry>/switchboard:<tag>"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.switchboard.repository_id}"
}

output "cluster_name" {
  description = "Empty when cluster_enabled = false."
  value       = one(google_container_cluster.switchboard[*].name)
}

output "connect" {
  description = "Point kubectl at the cluster."
  value       = var.cluster_enabled ? "gcloud container clusters get-credentials ${var.cluster_name} --region ${var.region} --project ${var.project_id}" : "cluster is off (cluster_enabled = false)"
}
