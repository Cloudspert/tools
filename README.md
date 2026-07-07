# tools

A collection of standalone scripts/utilities. Each tool lives in its own
directory with this layout:

```
tools/
  <tool-name>/
    <tool-name>.sh        # the script itself (or whatever entrypoint(s) it needs)
    docs/
      README.md           # usage, requirements, exit codes, limitations
```

## Convention for adding a new tool

1. Create `tools/<tool-name>/`.
2. Put the executable script(s) directly in that directory.
3. Add `tools/<tool-name>/docs/README.md` covering:
   - What the tool does and why it's needed.
   - Requirements (binaries it shells out to, privileges, etc.).
   - Usage examples (all supported argument forms).
   - Output format.
   - Exit codes and what each means.
   - Known limitations / edge cases.
4. Add a one-line entry to the index below.

## Index

| Tool | Description |
|---|---|
| [containerd-snapshot-to-image](containerd-snapshot-to-image/docs/README.md) | Resolve a containerd overlayfs snapshot directory to the image(s) that reference it |
