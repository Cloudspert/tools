# --------------------------------------------------------------------------
# REMOTE STATE -- this is what makes "run once per vm" hold across machines.
#
# The api cannot tell you whether a job was already done, so the terraform
# state is the only durable record. With a local terraform.tfstate, a second
# machine (another node, your pc, a ci runner) starts from an empty state,
# sees no vm as done, and relaunches every job.
#
# Uncomment the block matching your infra, fill it in, then:
#   terraform init -migrate-state
#
# Locking matters here: without it two applies at the same time can both
# launch the same job. s3 (with dynamodb or use_lockfile), gcs, azurerm and
# terraform cloud all support it.
# --------------------------------------------------------------------------

terraform {
  # --- AWS S3 -------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "CHANGE_ME-tf-state"
  #   key            = "jobs/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "CHANGE_ME-tf-locks" # state locking
  #   encrypt        = true
  # }

  # --- Google GCS ---------------------------------------------------------
  # backend "gcs" {
  #   bucket = "CHANGE_ME-tf-state"
  #   prefix = "jobs"
  # }

  # --- Azure --------------------------------------------------------------
  # backend "azurerm" {
  #   resource_group_name  = "CHANGE_ME"
  #   storage_account_name = "CHANGE_ME"
  #   container_name       = "tfstate"
  #   key                  = "jobs.terraform.tfstate"
  # }

  # --- HCP Terraform / Terraform Enterprise -------------------------------
  # cloud {
  #   organization = "CHANGE_ME"
  #   workspaces {
  #     name = "jobs"
  #   }
  # }
}
