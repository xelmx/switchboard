variable "project_id" {
  description = "The GCP project. Created by hand (or by gcloud) before Terraform runs - see NOTES.md, task 5."
  type        = string
}

variable "region" {
  description = "Where the cluster and the registry both live. Singapore is the closest region to Manila; putting the registry anywhere else means every image pull crosses a continent and is billed as egress."
  type        = string
  default     = "asia-southeast1"
}

variable "cluster_name" {
  type    = string
  default = "switchboard"
}

variable "repo_name" {
  description = "Artifact Registry repository for the service image."
  type        = string
  default     = "switchboard"
}

variable "cluster_enabled" {
  description = "false removes the cluster (the part that bills by the hour) and keeps the registry and its image (cents per month). End every session with it off; see scripts/destroy-task5.sh."
  type        = bool
  default     = true
}
