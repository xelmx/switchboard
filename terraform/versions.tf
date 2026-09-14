# Pinned on purpose. A provider that floats to a new major version between two
# `terraform apply`s is a plan you didn't write.
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # State is a local file, gitignored. A team puts it in a GCS bucket so two
  # people can't apply at once - but that bucket has to exist before Terraform
  # runs, which is the bootstrap problem every project hits once. Task 11 can
  # revisit; for one person on one laptop, local state is honest.
}

provider "google" {
  project = var.project_id
  region  = var.region
}
