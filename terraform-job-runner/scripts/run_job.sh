#!/usr/bin/env bash
#
# Launch a job through the API, wait for it to finish, exit 0 (success) or 1 (failure).
#
# All inputs come from environment variables so the token never lands in a
# process command line (Terraform passes them via `environment { ... }`).
#
#   API_URL        base url of the api, e.g. https://api.example.com
#   API_TOKEN      bearer token used for validation
#   VM_NAME        name of the vm this run is for
#   VM_ROLE        role of the vm (master, worker, db, ...)
#
# Optional:
#   POLL_INTERVAL  seconds between status checks         (default 10)
#   JOB_TIMEOUT    max seconds to wait for the job       (default 1800)
#   MARKER_DIR     where the "already done" marker goes  (default /var/lib/job-runner)
#   SKIP_IF_DONE   1 = skip if a success marker exists   (default 1)
#
# "run once per vm" is enforced by the terraform state, not by this script:
# the resource exists in the (remote) state after the first apply, so the
# provisioner is never launched again. The marker below is only a local
# fast path for when the script is run by hand outside terraform.

set -euo pipefail

API_URL="${API_URL:?API_URL is required}"
API_TOKEN="${API_TOKEN:?API_TOKEN is required}"
VM_NAME="${VM_NAME:?VM_NAME is required}"
VM_ROLE="${VM_ROLE:?VM_ROLE is required}"

POLL_INTERVAL="${POLL_INTERVAL:-10}"
JOB_TIMEOUT="${JOB_TIMEOUT:-1800}"
MARKER_DIR="${MARKER_DIR:-/var/lib/job-runner}"
SKIP_IF_DONE="${SKIP_IF_DONE:-1}"

MARKER_FILE="${MARKER_DIR}/${VM_NAME}-${VM_ROLE}.json"

# stable key for this vm+role, used so the api can deduplicate the request
# whatever machine the script runs from
IDEMPOTENCY_KEY="${VM_NAME}-${VM_ROLE}"

log()  { printf '%s [%s/%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VM_NAME" "$VM_ROLE" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is not installed"
command -v jq   >/dev/null 2>&1 || fail "jq is not installed"

# --------------------------------------------------------------------------
# 0a. already done on THIS machine? (local fast path, no api call)
# --------------------------------------------------------------------------
if [[ "$SKIP_IF_DONE" == "1" && -f "$MARKER_FILE" ]]; then
  previous_id="$(jq -r '.job_id // "unknown"' "$MARKER_FILE" 2>/dev/null || echo unknown)"
  log "local marker found (job_id=${previous_id}), skipping"
  cat "$MARKER_FILE"
  exit 0
fi

# --------------------------------------------------------------------------
# 1. launch the job
# --------------------------------------------------------------------------
# dummy payload -- edit the fields here when the real contract is known.
# ${VM_NAME} and ${VM_ROLE} are substituted by the shell.
payload=$(cat <<EOF
{
  "vm_name": "${VM_NAME}",
  "role": "${VM_ROLE}",
  "action": "dummy_action",
  "params": {
    "key1": "value1",
    "key2": "value2"
  }
}
EOF
)

log "launching job: ${payload}"

response="$(curl -sS \
  --max-time 60 \
  --retry 3 --retry-delay 5 --retry-connrefused \
  -w '\n%{http_code}' \
  -X POST "${API_URL}/jobs" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEMPOTENCY_KEY}" \
  -d "$payload")" || fail "could not reach ${API_URL}/jobs"

http_code="$(tail -n1 <<<"$response")"
body="$(sed '$d' <<<"$response")"

if [[ "$http_code" != "200" && "$http_code" != "201" && "$http_code" != "202" ]]; then
  fail "job creation failed (http ${http_code}): ${body}"
fi

JOB_ID="$(jq -r '.job_id // empty' <<<"$body")"
[[ -n "$JOB_ID" ]] || fail "no job_id in the response: ${body}"

log "job created: job_id=${JOB_ID}"

# --------------------------------------------------------------------------
# 2. wait for the job to finish
# --------------------------------------------------------------------------
deadline=$(( $(date +%s) + JOB_TIMEOUT ))
status=""
status_body=""

while :; do
  if (( $(date +%s) >= deadline )); then
    fail "timeout after ${JOB_TIMEOUT}s, job ${JOB_ID} last status=${status:-unknown}"
  fi

  status_response="$(curl -sS \
    --max-time 30 \
    --retry 3 --retry-delay 5 --retry-connrefused \
    -w '\n%{http_code}' \
    -X GET "${API_URL}/jobs/${JOB_ID}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Accept: application/json")" || { log "status call failed, retrying"; sleep "$POLL_INTERVAL"; continue; }

  status_code="$(tail -n1 <<<"$status_response")"
  status_body="$(sed '$d' <<<"$status_response")"

  if [[ "$status_code" != "200" ]]; then
    log "unexpected http ${status_code} while polling, retrying: ${status_body}"
    sleep "$POLL_INTERVAL"
    continue
  fi

  status="$(jq -r '.status // empty' <<<"$status_body" | tr '[:lower:]' '[:upper:]')"

  case "$status" in
    SUCCESS|SUCCEEDED|COMPLETED|DONE)
      log "job ${JOB_ID} finished successfully"
      break
      ;;
    FAILED|ERROR|CANCELLED|CANCELED)
      error_msg="$(jq -r '.error // .message // "no error message returned"' <<<"$status_body")"
      fail "job ${JOB_ID} ended with status=${status}: ${error_msg}"
      ;;
    PENDING|QUEUED|RUNNING|IN_PROGRESS)
      log "job ${JOB_ID} status=${status}, waiting ${POLL_INTERVAL}s"
      sleep "$POLL_INTERVAL"
      ;;
    "")
      log "no status field in the response, retrying: ${status_body}"
      sleep "$POLL_INTERVAL"
      ;;
    *)
      fail "job ${JOB_ID} returned an unknown status=${status}: ${status_body}"
      ;;
  esac
done

# --------------------------------------------------------------------------
# 3. record the result + print it as json on stdout
# --------------------------------------------------------------------------
result="$(jq -nc \
  --arg job_id  "$JOB_ID" \
  --arg vm_name "$VM_NAME" \
  --arg role    "$VM_ROLE" \
  --arg status  "$status" \
  --arg ended   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{job_id: $job_id, vm_name: $vm_name, role: $role, status: $status, finished_at: $ended}')"

if mkdir -p "$MARKER_DIR" 2>/dev/null; then
  printf '%s\n' "$result" > "$MARKER_FILE"
else
  log "warning: could not write the marker in ${MARKER_DIR}"
fi

printf '%s\n' "$result"
exit 0
