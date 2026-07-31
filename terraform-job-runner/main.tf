terraform {
  required_version = ">= 1.4"
}

# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
variable "api_url" {
  description = "Base url of the api, e.g. https://api.example.com"
  type        = string
}

variable "api_token" {
  description = "Token used by the api for validation"
  type        = string
  sensitive   = true
}

variable "vms" {
  description = "One entry per vm: key = vm name, value = role"
  type        = map(string)
  default = {
    "vm-01" = "master"
    "vm-02" = "worker"
    "vm-03" = "worker"
  }
}

variable "rerun_on_script_change" {
  description = "true = editing run_job.sh relaunches the job on every vm"
  type        = bool
  default     = false
}

variable "poll_interval" {
  description = "Seconds between two status checks"
  type        = number
  default     = 10
}

variable "job_timeout" {
  description = "Max seconds to wait for a job before failing"
  type        = number
  default     = 1800
}

# --------------------------------------------------------------------------
# One object per vm in the state.
#
# The provisioner is a CREATE-time action: it runs the first time this object
# is created and never again. On any later apply -- from this machine, another
# node, a ci runner -- terraform sees the object already in the (remote) state
# and does nothing. That is what makes the job run once per vm.
#
# It runs again only when a value in triggers_replace changes, or when the
# object is explicitly replaced:
#   terraform apply -replace='terraform_data.job["vm-01"]'
# --------------------------------------------------------------------------
resource "terraform_data" "job" {
  for_each = var.vms

  triggers_replace = merge(
    {
      vm_name = each.key
      role    = each.value
    },
    var.rerun_on_script_change ? {
      script = filesha256("${path.module}/scripts/run_job.sh")
    } : {}
  )

  provisioner "local-exec" {
    command     = "${path.module}/scripts/run_job.sh"
    interpreter = ["/usr/bin/env", "bash"]

    # env vars, not command line arguments: the token never shows up in a
    # process listing nor in the command echoed by terraform.
    environment = {
      API_URL       = var.api_url
      API_TOKEN     = var.api_token
      VM_NAME       = each.key
      VM_ROLE       = each.value
      POLL_INTERVAL = tostring(var.poll_interval)
      JOB_TIMEOUT   = tostring(var.job_timeout)

      # the marker is written for audit/debug, but NOT read when terraform
      # drives the script: the state is the authority. otherwise a forced
      # `apply -replace=...` would find an old marker and skip the job on the
      # machine that holds it, while re-running it on any other machine.
      MARKER_DIR   = "${path.module}/.jobs"
      SKIP_IF_DONE = "0"
    }
  }
}

# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------
output "jobs_done" {
  description = "vm -> role for every vm whose job completed successfully"
  value       = { for k, r in terraform_data.job : k => r.triggers_replace.role }
}
