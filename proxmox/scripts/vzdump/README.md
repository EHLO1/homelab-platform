# Proxmox VE Backup Hook Scripts
Copied and modified from: https://www.thk-systems.net/proxmox-vzdump-hooks/
Intended to be set as the default hook script target in /etc/vzdump.conf
`script: /usr/local/scripts/hook-dispatcher.sh`

hook-dispatcher.sh
- Automatically runs every time vzdump is called (backup jobs)
- Delegates actions to sub scripts based on the backup job
- It's intended to be generic; If an action exists, it runs, if not, nothing happens
- Has 2 modes: Synchronous (blocking) & Asynchronous (non-blocking)

The dispatcher is responsible for:
- parsing the vzdump phase
- scanning a hooks.d/ directory
- reading a small configuration header from each hook script
- deciding if and how to run it

How hook headers work
Each hook script starts with a short, structured comment header.
This header is not documentation — it is machine-readable configuration for the dispatcher.

Only the initial comment block is read. As soon as the first non-comment line is reached, parsing stops. This keeps the mechanism simple, predictable, and independent of the script body.

A hook may declare:
- `# mode: sync | async`
  - Controls execution behavior:
    - sync: run inline, may block vzdump
    - async (default): detached background execution
- `# phases: <phase> [<phase> …]`
  - Lists the vzdump phases in which the hook should run (for example: log-end)
- `# mk-job`
  - Optional flag that wraps the hook execution in a managed check_mk job

Example header:
```Bash
#!/usr/bin/env bash
# mode: async
# phases: log-end
# mk-job
```
**AKA** -> Run this hook during the log-end phase, execute it asynchronously, register it as a check_mk jo

