# A registry is the shared image store every node pulls from - the thing task 3
# found missing when the cluster node couldn't see an image built by Docker on
# the same machine. `docker exec ... ctr images import` was the laptop
# workaround; this is the real answer.
resource "google_artifact_registry_repository" "switchboard" {
  location      = var.region
  repository_id = var.repo_name
  description   = "Parakeet-TDT speech-to-text service images"
  format        = "DOCKER"

  # The image is ~17 GB uncompressed and carries the model weights, so old
  # versions are not cheap to keep. Keep the last few; delete the rest.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  depends_on = [google_project_service.enabled]
}
