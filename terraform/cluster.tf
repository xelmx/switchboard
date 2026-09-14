# GKE Autopilot: Google runs the nodes. You declare pods with CPU and memory
# requests; nodes appear and disappear to fit them, and you are billed for what
# the pods requested rather than for machines you sized by hand.
#
# Why Autopilot and not Standard, for this project: task 3's resource requests
# already say what a pod needs, and that is the only input Autopilot wants.
# There is no node pool to size, no autoscaler to tune, and no idle node left
# running overnight because nobody drained it.
resource "google_container_cluster" "switchboard" {
  name     = var.cluster_name
  location = var.region

  enable_autopilot = true

  # Required for Autopilot: pods and services get their own IP ranges, assigned
  # by GKE. An empty block means "you pick".
  ip_allocation_policy {}

  release_channel {
    channel = "REGULAR"
  }

  # The provider defaults this to true, and it does exactly what it says:
  # `terraform destroy` is refused, with an error that reads like a bug. This
  # project is meant to be torn down (task 11), so it is off - deliberately,
  # not by accident.
  deletion_protection = false

  depends_on = [google_project_service.enabled]
}
