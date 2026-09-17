# Cloud Build runs as the project's Compute Engine default service account, and
# in a new project that account starts with nothing useful. The first
# `gcloud builds submit` then fails on permissions - pushing to Artifact
# Registry, reading the uploaded source, or writing logs - and the error names
# a service account nobody created, which makes it hard to place.
#
# roles/cloudbuild.builds.builder is Google's own bundle for exactly this: the
# storage, Artifact Registry and logging permissions a build needs. A team with
# an organisation policy would give builds a dedicated service account instead;
# for one project owned by one person, this is the documented default.
data "google_project" "this" {
  project_id = var.project_id

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "cloudbuild_default" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# The same account is also what GKE Autopilot nodes run as. In an organisation
# created after 2024 the policy iam.automaticIamGrantsForDefaultServiceAccounts
# is enforced, so it no longer gets Editor automatically - and a node with no
# roles cannot pull the image from Artifact Registry (ImagePullBackOff, 403) or
# send its logs and metrics. These are the two grants GKE's docs call for.
resource "google_project_iam_member" "node_default" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount", # logs, metrics, node reporting
    "roles/artifactregistry.reader",             # pull the image
  ])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}
