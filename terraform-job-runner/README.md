# terraform-job-runner

Launches a job through an API for each VM, waits for it to finish, and records
the result in the Terraform state so it never runs twice for the same VM.

```
main.tf                          one terraform_data per vm + variables/outputs
backend.tf                       remote state (uncomment the one you use)
scripts/run_job.sh               launch + poll + exit 0/1
variants/shell_script.tf.disabled  alternative that stores job_id in the state
terraform.tfvars.example         copy to terraform.tfvars
```

## The script

Inputs are env vars, so the token never appears in a process listing:

| var | required | default | meaning |
|---|---|---|---|
| `API_URL` | yes | | base url, e.g. `https://api.example.com` |
| `API_TOKEN` | yes | | sent as `Authorization: Bearer` |
| `VM_NAME` | yes | | name of the vm |
| `VM_ROLE` | yes | | role of the vm |
| `POLL_INTERVAL` | no | `10` | seconds between status checks |
| `JOB_TIMEOUT` | no | `1800` | max wait before failing |
| `MARKER_DIR` | no | `/var/lib/job-runner` | where the success marker is written |
| `SKIP_IF_DONE` | no | `1` | skip if a local marker already exists |

Flow:

1. `POST ${API_URL}/jobs` with a **dummy JSON payload** (edit it in the script
   when the real contract is known) and an `Idempotency-Key` header → reads
   `.job_id`.
2. Polls `GET ${API_URL}/jobs/${job_id}` until `.status` is terminal.
   `SUCCESS|SUCCEEDED|COMPLETED|DONE` → **exit 0**.
   `FAILED|ERROR|CANCELLED` → **exit 1** with `.error` (or `.message`).
   Timeout → exit 1. Transient HTTP errors are retried.
3. On success writes `${MARKER_DIR}/${VM_NAME}-${VM_ROLE}.json` and prints the
   same JSON on stdout.

Needs `curl` and `jq` (jq only parses the responses; the payload is plain text).

Run it standalone:

```bash
API_URL=https://api.example.com API_TOKEN=xxx VM_NAME=vm-01 VM_ROLE=master ./scripts/run_job.sh
```

## Running it once per VM, from any machine

The API cannot tell you whether a job was already done, so **the Terraform
state is the only durable record**.

- `terraform_data.job["vm-01"]` is one object in the state. Its `local-exec`
  provisioner is a create-time action: it runs when the object is created and
  never again.
- Any later `apply` — from your PC, another node, a CI runner — sees the object
  already in state and does nothing.
- This only holds if every machine reads the **same state**: fill in
  `backend.tf` and run `terraform init -migrate-state`. Keep state locking on,
  otherwise two simultaneous applies can both launch the same job.
- Under Terraform the marker file is written but **not read**
  (`SKIP_IF_DONE=0` in `main.tf`) — it is an audit trail, not the authority.
  If it were read, a forced `-replace` would silently skip the job on the
  machine holding the old marker while re-running it everywhere else.
  Standalone runs of the script still default to `SKIP_IF_DONE=1`.

Re-running is explicit:

```bash
terraform apply -replace='terraform_data.job["vm-01"]'
```

Set `rerun_on_script_change = true` if editing `run_job.sh` should relaunch the
job on every VM (off by default).

## Usage

```bash
export TF_VAR_api_token='...'
terraform init
terraform apply -var api_url=https://api.example.com
```

Check it behaves:

| step | expected |
|---|---|
| first `apply` | jobs run, one per vm |
| second `apply` | `No changes` |
| `apply` from another machine (same backend) | `No changes` |
| adding a vm to `vms` | only the new vm runs |
| changing a vm's role | only that vm re-runs |
| `apply -replace='terraform_data.job["vm-01"]'` | only vm-01 re-runs |

## If you need the job_id in the state

A provisioner cannot return a value, so `terraform_data` records only "this VM
ran". To keep the API response in state, use
`variants/shell_script.tf.disabled` (the `scottwinkler/shell` provider): it
parses the JSON the script prints on stdout and exposes
`shell_script.job["vm-01"].output["job_id"]`. Same once-per-VM behaviour.
