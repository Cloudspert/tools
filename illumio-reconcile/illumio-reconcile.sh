#!/usr/bin/env bash
#
# illumio-reconcile.sh
#
# Fan out from a Kamaji management cluster into every tenant control plane and
# reconcile the `illumio_install` key of a configmap on each TENANT cluster.
#
# Per tenant:
#   * illumio-system namespace exists AND illumio-ven daemonset exists -> "container"
#   * otherwise (missing, or present without the VEN daemonset)         -> "rpm"
#
# Detection AND the patch both happen on the tenant cluster. The management
# cluster is only read from (list namespaces + pull kubeconfig secrets).
#
# Dry-run by default: pass --apply to actually write.
#
set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults (all overridable via flags)
# ---------------------------------------------------------------------------
SELECTOR=""                       # label selector to pick tenant namespaces on the mgmt cluster (required)
SKIP_LABEL="illumio.io/skip"      # if this label is present (any value) on the ns -> skip
SKIP_ANNOTATION="illumio.io/skip" # if this annotation == a truthy value on the ns -> skip
NAMESPACE="kube-system"         # namespace on the TENANT cluster holding the configmap
CONFIGMAP="illumio-config"      # configmap on the TENANT cluster to patch
CM_KEY="illumio_install"          # data key inside the configmap
ILLUMIO_NS="illumio-system"       # namespace whose existence we check on the tenant
ILLUMIO_DS="illumio-ven"          # daemonset whose existence flips us to "container"
KUBECONFIG_KEY="admin.conf"       # data key inside the <cluster-id>-admin-kubeconfig secret
SECRET_SUFFIX="-admin-kubeconfig" # discover the kubeconfig secret by this name suffix (cluster-id != ns)
SECRET_NAME=""                    # explicit secret name override (skips discovery)
CLUSTER_ID_LABEL=""               # if set, build secret name as <label-value><SECRET_SUFFIX> instead of discovering
MGMT_KUBECONFIG=""                # kubeconfig for the mgmt cluster (default: current context)
MGMT_CONTEXT=""                   # context for the mgmt cluster (default: current)
TENANT_TIMEOUT="15s"              # per-call timeout when talking to a tenant
CONCURRENCY=1                     # parallel tenants (1 = serial)
APPLY=false                       # false = dry-run (print intended change, write nothing)
REPLACE=false                     # false = if the CM key already exists, skip it (don't overwrite)

# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --selector <label-selector> [options]

Required:
  --selector SEL        Label selector to choose tenant namespaces on the mgmt cluster
                        (e.g. "kamaji.clastix.io/project=prod").

Targeting / naming:
  --namespace NS      Tenant namespace holding the configmap        (default: ${NAMESPACE})
  --configmap NAME    Configmap to patch on the tenant              (default: ${CONFIGMAP})
  --cm-key KEY          Data key to set in the configmap              (default: ${CM_KEY})
  --illumio-ns NS       Namespace to detect on the tenant             (default: ${ILLUMIO_NS})
  --illumio-ds NAME     Daemonset that means "container" install      (default: ${ILLUMIO_DS})

Kubeconfig secret (by default discovered by name suffix, since cluster-id != ns):
  --kubeconfig-key KEY  Data key inside the admin-kubeconfig secret   (default: ${KUBECONFIG_KEY})
  --secret-suffix S     Discover the secret whose name ends with this (default: ${SECRET_SUFFIX})
  --secret-name NAME    Use this exact secret name; skips discovery.
  --cluster-id-label L  Build the name as <label-value><suffix> from this ns label instead of discovering.

Skip rules:
  --skip-label KEY      Skip a namespace if it carries this label     (default: ${SKIP_LABEL})
  --skip-annotation KEY Skip a namespace if this annotation is truthy (default: ${SKIP_ANNOTATION})

Management cluster:
  --mgmt-kubeconfig F   Kubeconfig for the mgmt cluster               (default: current)
  --mgmt-context CTX    Context for the mgmt cluster                  (default: current)

Execution:
  --tenant-timeout DUR  Per-request timeout against a tenant          (default: ${TENANT_TIMEOUT})
  --concurrency N       Number of tenants to process in parallel      (default: ${CONCURRENCY})
  --apply               Actually patch. Without this flag, dry-run only.
  --replace             Overwrite ${CM_KEY} even if it already exists in the configmap.
                        Default: if the key is already present, that tenant is skipped.
  -h, --help            Show this help.
EOF
  exit "${1:-0}"
}

log()  { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "${2:-INFO}" "$1" >&2; }
die()  { log "$1" ERROR; exit 1; }

# Write one status line for the current tenant. Relies on dynamic scope:
# $ns and $result_file are locals of the calling process_namespace.
record() { printf '%s\t%s\t%s\n' "$1" "$ns" "${2:-}" > "$result_file"; }

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selector)         SELECTOR="$2"; shift 2;;
    --namespace)      NAMESPACE="$2"; shift 2;;
    --configmap)      CONFIGMAP="$2"; shift 2;;
    --cm-key)           CM_KEY="$2"; shift 2;;
    --illumio-ns)       ILLUMIO_NS="$2"; shift 2;;
    --illumio-ds)       ILLUMIO_DS="$2"; shift 2;;
    --kubeconfig-key)   KUBECONFIG_KEY="$2"; shift 2;;
    --secret-suffix)    SECRET_SUFFIX="$2"; shift 2;;
    --secret-name)      SECRET_NAME="$2"; shift 2;;
    --cluster-id-label) CLUSTER_ID_LABEL="$2"; shift 2;;
    --skip-label)       SKIP_LABEL="$2"; shift 2;;
    --skip-annotation)  SKIP_ANNOTATION="$2"; shift 2;;
    --mgmt-kubeconfig)  MGMT_KUBECONFIG="$2"; shift 2;;
    --mgmt-context)     MGMT_CONTEXT="$2"; shift 2;;
    --tenant-timeout)   TENANT_TIMEOUT="$2"; shift 2;;
    --concurrency)      CONCURRENCY="$2"; shift 2;;
    --apply)            APPLY=true; shift;;
    --replace)          REPLACE=true; shift;;
    -h|--help)          usage 0;;
    *) log "Unknown argument: $1" ERROR; usage 1;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[[ -n "$SELECTOR" ]] || { log "--selector is required" ERROR; usage 1; }
[[ "$CONCURRENCY" =~ ^[0-9]+$ && "$CONCURRENCY" -ge 1 ]] || die "--concurrency must be a positive integer"

# kubectl invocation for the management cluster
mgmt_kubectl() {
  local args=()
  [[ -n "$MGMT_KUBECONFIG" ]] && args+=(--kubeconfig "$MGMT_KUBECONFIG")
  [[ -n "$MGMT_CONTEXT" ]]    && args+=(--context "$MGMT_CONTEXT")
  kubectl "${args[@]}" "$@"
}

# Scratch dir for decoded kubeconfigs + per-tenant result files
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/illumio-reconcile.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Per-tenant worker. Writes exactly one status line to $WORKDIR/results/<ns>:
#   PATCHED | WOULDPATCH | NOCHANGE | SKIPPED | UNREACHABLE | ERROR <tab> ns <tab> detail
# All human logging goes to stderr; the result file is the machine record.
# ---------------------------------------------------------------------------
process_namespace() {
  local ns="$1"
  local result_file="$WORKDIR/results/$ns"
  local kubeconfig="$WORKDIR/kubeconfig-$ns"

  # --- skip rules (read labels + annotations off the ns object) ---------------
  if [[ -n "$SKIP_LABEL" ]]; then
    local lv
    lv="$(mgmt_kubectl get ns "$ns" -o "jsonpath={.metadata.labels.${SKIP_LABEL//./\\.}}" 2>/dev/null || true)"
    if [[ -n "$lv" ]]; then
      log "[$ns] skip-label '$SKIP_LABEL' present -> skipping" WARN
      record SKIPPED "label:$SKIP_LABEL"; return 0
    fi
  fi
  if [[ -n "$SKIP_ANNOTATION" ]]; then
    local av
    av="$(mgmt_kubectl get ns "$ns" -o "jsonpath={.metadata.annotations.${SKIP_ANNOTATION//./\\.}}" 2>/dev/null || true)"
    case "${av,,}" in
      true|yes|1|skip)
        log "[$ns] skip-annotation '$SKIP_ANNOTATION=$av' -> skipping" WARN
        record SKIPPED "annotation:$SKIP_ANNOTATION=$av"; return 0;;
    esac
  fi

  # --- locate the admin-kubeconfig secret in this namespace ------------------
  # The cluster-id does NOT match the namespace name, so we can't build
  # "<ns>-admin-kubeconfig". Resolution order:
  #   1. --secret-name         : use it verbatim
  #   2. --cluster-id-label    : build <label-value><suffix>
  #   3. default (discovery)   : the secret in this ns whose name ends with suffix
  local secret=""
  if [[ -n "$SECRET_NAME" ]]; then
    secret="$SECRET_NAME"
  elif [[ -n "$CLUSTER_ID_LABEL" ]]; then
    local cid
    cid="$(mgmt_kubectl get ns "$ns" -o "jsonpath={.metadata.labels.${CLUSTER_ID_LABEL//./\\.}}" 2>/dev/null || true)"
    [[ -n "$cid" ]] || { log "[$ns] cluster-id label '$CLUSTER_ID_LABEL' empty" ERROR; record ERROR "no-cluster-id"; return 0; }
    secret="${cid}${SECRET_SUFFIX}"
  else
    # Pure-bash suffix match: the suffix begins with '-', which grep would parse
    # as options, so glob-compare each secret name instead.
    local sname matches=() count
    while IFS= read -r sname; do
      [[ -n "$sname" ]] || continue
      [[ "$sname" == *"$SECRET_SUFFIX" ]] && matches+=("$sname")
    done < <(mgmt_kubectl get secrets -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
    count=${#matches[@]}
    if [[ "$count" -eq 0 ]]; then
      log "[$ns] no secret matching '*${SECRET_SUFFIX}' found" ERROR
      record ERROR "no-kubeconfig-secret"; return 0
    fi
    secret="${matches[0]}"
    [[ "$count" -gt 1 ]] && log "[$ns] $count secrets match '*${SECRET_SUFFIX}'; using '$secret'" WARN
  fi
  local cluster_id="${secret%"$SECRET_SUFFIX"}"

  local b64
  b64="$(mgmt_kubectl get secret "$secret" -n "$ns" -o "jsonpath={.data.${KUBECONFIG_KEY//./\\.}}" 2>/dev/null || true)"
  if [[ -z "$b64" ]]; then
    log "[$ns] secret '$secret' key '$KUBECONFIG_KEY' not found" ERROR
    record ERROR "no-kubeconfig"; return 0
  fi
  ( umask 077; printf '%s' "$b64" | base64 --decode > "$kubeconfig" ) \
    || { log "[$ns] failed to decode kubeconfig" ERROR; record ERROR "decode"; return 0; }

  local tk=(kubectl --kubeconfig "$kubeconfig" --request-timeout "$TENANT_TIMEOUT")

  # --- reachability guard -----------------------------------------------------
  if ! "${tk[@]}" get --raw='/readyz' >/dev/null 2>&1 && ! "${tk[@]}" get ns >/dev/null 2>&1; then
    log "[$ns] tenant '$cluster_id' unreachable" WARN
    record UNREACHABLE "unreachable"; return 0
  fi

  # --- detect on the tenant ---------------------------------------------------
  local desired="rpm"
  if "${tk[@]}" get ns "$ILLUMIO_NS" >/dev/null 2>&1; then
    if "${tk[@]}" get daemonset "$ILLUMIO_DS" -n "$ILLUMIO_NS" >/dev/null 2>&1; then
      desired="container"
    else
      log "[$ns] '$ILLUMIO_NS' present but no '$ILLUMIO_DS' daemonset -> rpm" INFO
    fi
  fi

  if ! "${tk[@]}" get configmap "$CONFIGMAP" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "[$ns] configmap '$CONFIGMAP' not found in ns '$NAMESPACE'" ERROR
    record ERROR "no-configmap"; return 0
  fi

  # --- read current value + key presence --------------------------------------
  # jsonpath returns "" for both an absent key and an empty value, so use a
  # go-template hasKey check to tell them apart.
  local current key_exists
  current="$("${tk[@]}" get configmap "$CONFIGMAP" -n "$NAMESPACE" \
              -o "jsonpath={.data.${CM_KEY//./\\.}}" 2>/dev/null || true)"
  key_exists="$("${tk[@]}" get configmap "$CONFIGMAP" -n "$NAMESPACE" \
              -o "go-template={{if .data}}{{if hasKey .data \"${CM_KEY}\"}}true{{end}}{{end}}" 2>/dev/null || true)"

  # Key already set: leave it alone unless --replace was given.
  if [[ "$key_exists" == "true" && "$REPLACE" != true ]]; then
    log "[$ns] $CM_KEY already present (='${current}'); --replace not set -> skipping" INFO
    record EXISTS "present:${current}"; return 0
  fi

  if [[ "$current" == "$desired" ]]; then
    log "[$ns] $CM_KEY already '$desired' -> no change" INFO
    record NOCHANGE "$desired"; return 0
  fi

  # --- patch (or dry-run) -----------------------------------------------------
  local patch
  patch="$(printf '{"data":{"%s":"%s"}}' "$CM_KEY" "$desired")"
  if [[ "$APPLY" == true ]]; then
    if "${tk[@]}" patch configmap "$CONFIGMAP" -n "$NAMESPACE" --type merge -p "$patch" >/dev/null 2>&1; then
      log "[$ns] patched $CM_KEY: '${current:-<unset>}' -> '$desired'" INFO
      record PATCHED "${current:-<unset>}->$desired"
    else
      log "[$ns] patch failed" ERROR
      record ERROR "patch-failed"
    fi
  else
    log "[$ns] DRY-RUN would set $CM_KEY: '${current:-<unset>}' -> '$desired'" INFO
    record WOULDPATCH "${current:-<unset>}->$desired"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main: list namespaces, then process with bounded concurrency
# ---------------------------------------------------------------------------
mkdir -p "$WORKDIR/results"

mapfile -t NAMESPACES < <(mgmt_kubectl get ns -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sed '/^$/d')
[[ ${#NAMESPACES[@]} -gt 0 ]] || die "No namespaces matched selector '$SELECTOR'"

log "Selected ${#NAMESPACES[@]} tenant namespace(s); apply=$APPLY concurrency=$CONCURRENCY"

running=0
for ns in "${NAMESPACES[@]}"; do
  process_namespace "$ns" &
  running=$((running + 1))
  if [[ "$running" -ge "$CONCURRENCY" ]]; then
    wait -n 2>/dev/null || wait   # -n needs bash>=4.3; fall back to wait-all
    running=$((running - 1))
  fi
done
wait

# ---------------------------------------------------------------------------
# Summary + exit code
# ---------------------------------------------------------------------------
declare -A COUNT=()
errors=0
printf '\n==== Summary ====\n' >&2
for f in "$WORKDIR"/results/*; do
  [[ -e "$f" ]] || continue
  IFS=$'\t' read -r status ns detail < "$f"
  COUNT[$status]=$(( ${COUNT[$status]:-0} + 1 ))
  [[ "$status" == "ERROR" ]] && { errors=$((errors+1)); printf '  ERROR       %-40s %s\n' "$ns" "$detail" >&2; }
done
for s in PATCHED WOULDPATCH NOCHANGE EXISTS SKIPPED UNREACHABLE ERROR; do
  printf '  %-11s %d\n' "$s" "${COUNT[$s]:-0}" >&2
done

[[ "$errors" -eq 0 ]] || exit 2
exit 0
