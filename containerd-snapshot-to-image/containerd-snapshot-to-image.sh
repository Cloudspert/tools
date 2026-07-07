#!/usr/bin/env bash
#
# containerd-snapshot-to-image.sh
#
# Resolve a local containerd snapshot directory (e.g. the numeric dir under
# .../io.containerd.snapshotter.v1.overlayfs/snapshots/<id>) to the container
# image(s) that reference it.
#
# There is no 1:1 mapping stored anywhere from "numeric snapshot id" -> "image":
# the numeric id is an internal snapshotter detail. The only reliable way to
# find the image is to walk every container's snapshot mount chain
# (lowerdir/upperdir, which lists every numeric snapshot dir in its lineage)
# and see whether the target id shows up in it. A layer can be shared by
# multiple images, so this can legitimately print more than one match.
#
# Usage:
#   ./containerd-snapshot-to-image.sh <snapshot-path> [namespace]
#   ./containerd-snapshot-to-image.sh -p <snapshot-path> [-n namespace] [-a address]
#
# Examples:
#   ./containerd-snapshot-to-image.sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111
#   ./containerd-snapshot-to-image.sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111 k8s.io

set -euo pipefail

DEFAULT_NAMESPACE="k8s.io"
NAMESPACE=""
SNAPSHOT_PATH=""
CTR_ADDRESS=""

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <snapshot-path> [namespace]
       $(basename "$0") -p <snapshot-path> [-n namespace] [-a address]

  snapshot-path   Path to the snapshot dir on disk, e.g.
                  /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111
  namespace       containerd namespace (default: ${DEFAULT_NAMESPACE})
  -a address      containerd socket address to pass to ctr (e.g. /run/containerd/containerd.sock)
EOF
  exit 1
}

# Support both flag-style and positional-style invocation.
if [[ "${1:-}" == -* ]]; then
  while getopts "p:n:a:h" opt; do
    case "$opt" in
      p) SNAPSHOT_PATH="$OPTARG" ;;
      n) NAMESPACE="$OPTARG" ;;
      a) CTR_ADDRESS="$OPTARG" ;;
      h) usage ;;
      *) usage ;;
    esac
  done
else
  SNAPSHOT_PATH="${1:-}"
  NAMESPACE="${2:-}"
fi

[[ -z "$SNAPSHOT_PATH" ]] && usage
NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"

command -v ctr >/dev/null 2>&1 || { echo "error: 'ctr' not found in PATH (needs to run on the containerd host)" >&2; exit 1; }

CTR=(ctr)
[[ -n "$CTR_ADDRESS" ]] && CTR+=(--address "$CTR_ADDRESS")
CTR+=(-n "$NAMESPACE")

# Strip trailing slash and pull off the numeric snapshot id.
SNAPSHOT_PATH="${SNAPSHOT_PATH%/}"
SNAP_ID="$(basename "$SNAPSHOT_PATH")"
if ! [[ "$SNAP_ID" =~ ^[0-9]+$ ]]; then
  echo "error: could not parse a numeric snapshot id from '$SNAPSHOT_PATH'" >&2
  exit 1
fi

# Derive the snapshotter plugin name from the path itself
# (.../io.containerd.snapshotter.v1.<name>/snapshots/<id>), default to overlayfs.
SNAPSHOTTER="overlayfs"
if [[ "$SNAPSHOT_PATH" =~ io\.containerd\.snapshotter\.v1\.([a-zA-Z0-9_-]+)/snapshots ]]; then
  SNAPSHOTTER="${BASH_REMATCH[1]}"
fi

NEEDLE="/snapshots/${SNAP_ID}/"

echo "Resolving snapshot id ${SNAP_ID} (snapshotter=${SNAPSHOTTER}, namespace=${NAMESPACE})..." >&2

TMP_MOUNT="$(mktemp -d)"
trap 'rm -rf "$TMP_MOUNT"' EXIT

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

get_field() {
  # get_field <json> <field-name>
  local json="$1" field="$2"
  if [[ "$HAVE_JQ" -eq 1 ]]; then
    jq -r --arg f "$field" '.[$f] // empty' <<<"$json" 2>/dev/null
  else
    sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" <<<"$json" | head -n1
  fi
}

found_any=0

while read -r cid; do
  [[ -z "$cid" ]] && continue

  info_json="$("${CTR[@]}" containers info "$cid" 2>/dev/null || true)"
  [[ -z "$info_json" ]] && continue

  image="$(get_field "$info_json" Image)"
  snap_key="$(get_field "$info_json" SnapshotKey)"
  cur_snapshotter="$(get_field "$info_json" Snapshotter)"

  [[ -z "$snap_key" ]] && continue
  [[ -n "$cur_snapshotter" && "$cur_snapshotter" != "$SNAPSHOTTER" ]] && continue

  mounts="$("${CTR[@]}" snapshots --snapshotter "$SNAPSHOTTER" mounts "$TMP_MOUNT" "$snap_key" 2>/dev/null || true)"
  [[ -z "$mounts" ]] && continue

  if grep -qF -- "$NEEDLE" <<<"$mounts"; then
    echo "container=${cid}  image=${image}"
    found_any=1
  fi
done < <("${CTR[@]}" containers list -q 2>/dev/null)

if [[ "$found_any" -eq 0 ]]; then
  echo "No container in namespace '${NAMESPACE}' has snapshot ${SNAP_ID} in its mount chain." >&2
  echo "It may belong to a stopped/removed container, an intermediate/dangling layer," >&2
  echo "or a different namespace (try passing the right one, e.g. 'moby' for plain Docker)." >&2
  exit 2
fi
