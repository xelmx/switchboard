# Nothing in Google Cloud works until its API is switched on for the project.
# A cluster or a registry created against a disabled API fails with a message
# about the API, not about the thing you asked for - so these come first and
# everything else depends on them.
locals {
  services = [
    "compute.googleapis.com",          # the network the cluster runs on
    "container.googleapis.com",        # GKE itself
    "artifactregistry.googleapis.com", # where the image lives
    "cloudbuild.googleapis.com",       # builds the image inside Google's network
  ]
}

resource "google_project_service" "enabled" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.key

  # Leave the APIs on when this project is destroyed. Turning them off can
  # break other things in the same project, and it buys nothing: an enabled
  # API with no resources costs nothing.
  disable_on_destroy = false
}
