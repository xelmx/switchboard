output "registry" {
  description = "Prefix for the image: docker push <registry>/switchboard:<tag>"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.switchboard.repository_id}"
}

output "cluster_name" {
  value = google_container_cluster.switchboard.name
}

output "connect" {
  description = "Point kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.switchboard.name} --region ${var.region} --project ${var.project_id}"
}

output "build" {
  description = "Build the image inside Google's network - the 6.6 GB never crosses your connection."
  value       = "gcloud builds submit --region ${var.region} --tag ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.switchboard.repository_id}/switchboard:v1 ."
}
