locals {
  common_labels = {
    project = var.project_name
    owner   = var.owner
    env     = "training"
    stack   = "final-project"
  }
}
