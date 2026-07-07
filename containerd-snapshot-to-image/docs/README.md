# containerd-snapshot-to-image

Resolve a local containerd snapshot directory (e.g. a numeric dir under
`.../io.containerd.snapshotter.v1.overlayfs/snapshots/<id>`) to the container
image(s) that reference it.

## Why this is needed

The numeric snapshot id (`111111` in
`/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111`)
is an internal detail of the snapshotter — containerd does not expose a
direct "snapshot id -> image" lookup. The only reliable way to resolve it is
to walk every container's snapshot mount chain (its `lowerdir`/`upperdir`
entries, which enumerate every numeric snapshot dir in that container's
layer lineage) and check whether the target id shows up.

Because image layers are content-addressed and can be shared, a single
snapshot id can legitimately belong to more than one container/image. The
script prints every match it finds rather than assuming a 1:1 mapping.

## Requirements

- Must run on the containerd host itself (reads local snapshot state).
- `ctr` (the containerd CLI) must be on `PATH`.
- `jq` is used if available for safer JSON parsing; otherwise the script
  falls back to `sed`-based parsing of `ctr` output.
- Typically needs root / sufficient privileges to talk to the containerd
  socket (same privileges `ctr` normally requires).

## Usage

```bash
# positional form: <snapshot-path> [namespace]
./containerd-snapshot-to-image.sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111

# explicit namespace (default is k8s.io)
./containerd-snapshot-to-image.sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111 moby

# flag form, e.g. for a non-default containerd socket
./containerd-snapshot-to-image.sh -p /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/111111 \
  -n k8s.io -a /run/containerd/containerd.sock
```

### Arguments

| Arg | Flag | Description | Default |
|---|---|---|---|
| snapshot path | `-p` | Path to the snapshot dir on disk | (required) |
| namespace | `-n` | containerd namespace to search | `k8s.io` |
| address | `-a` | containerd socket address passed to `ctr --address` | ctr's own default |

The snapshotter name (`overlayfs`, etc.) is inferred automatically from the
path, e.g. `io.containerd.snapshotter.v1.overlayfs` -> `overlayfs`.

## Output

On success, one line per matching container:

```
container=<container-id>  image=<image-ref>
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | One or more matches found and printed |
| `1` | Usage error, missing `ctr`, or path did not contain a numeric snapshot id |
| `2` | No container in the given namespace references the snapshot id |

A `2` typically means the snapshot belongs to a stopped/removed container,
an intermediate/dangling layer no longer referenced by any container, or you
searched the wrong namespace (try `moby` for plain Docker instead of
`k8s.io`).

## Known limitations

- Only checks containers that currently exist in containerd's metadata
  store; a snapshot orphaned after its container was deleted won't resolve
  to an image via this method (containerd itself no longer has that
  association either).
- Assumes the `overlayfs` snapshotter's mount output includes the full
  numeric id lineage in `lowerdir`/`upperdir` — true for the default
  overlayfs snapshotter; other snapshotter plugins may format mounts
  differently.
