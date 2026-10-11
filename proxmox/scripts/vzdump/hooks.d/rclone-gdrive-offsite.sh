#!/usr/bin/env bash
# mode: sync
# phases: backup-end

set -euo pipefail

PHASE="${1:-}"
VMID="${3:-}"
BACKUP="${TARGET:-}"

[[ "$PHASE" == "backup-end" ]] || exit 0

[[ -f "$BACKUP" ]] || {
    echo "Backup file missing: $BACKUP" >&2
    exit 1
}

# Upload to Google Drive via encrypted rclone remote.
rclone copyto \
    "$BACKUP" \
    "gdrive-crypt:proxmox/${VMID}/$(basename "$BACKUP")"

echo "Offsite copy to Google Drive successful: $VMID"

exit 0