#!/usr/bin/env bash
# mode: sync
# phases: backup-start

set -euo pipefail

umask 077

GARAGE_VMID="102"
PHASE="${1:-}"
VMID="${3:-}"

[[ "$PHASE" == "backup-start" ]] || exit 0
[[ "$VMID" == "$GARAGE_VMID" ]] || exit 0

echo "Creating garage metadata snapshot..."

if ! pct exec "$VMID" -- \
    systemctl is-active --quiet garage.service; then
    echo "ERROR: Garage service is not running." >&2
    exit 1
fi

pct exec "$VMID" -- /usr/local/bin/garage meta snapshot

echo "Garage metadata snapshot completed."

exit 0