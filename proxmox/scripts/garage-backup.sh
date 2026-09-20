#!/usr/bin/env bash
#
# garage-backup.sh
# - Creates ZFS datasets if they do not already exist
# - Mounts associated directories to back the Garage LXC
# - Installs restic if it is not already
# - Deploys restic configuation for backing up garage
# - Idempotent
# - Doppler Secrets Manager is used to substitute secret values in template config
#
# Intended to be run from Proxmox VE

set -Eeuo pipefail
umask 077

# Config -------------------------------------------------------------------------
GARAGE_CTID="102"

GARAGE_META_ZFS_DATASET="primary-pool/garage/meta"
GARAGE_DATA_ZFS_DATASET="primary-pool/garage/data"
GARAGE_SNAPSHOTS_ZFS_DATASET="primary-pool/garage/snapshots"

GARAGE_META_ZFS_MOUNTPOINT="/mnt/garage/meta"
GARAGE_DATA_ZFS_MOUNTPOINT="/mnt/garage/data"
GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT="/mnt/garage/snapshots"

GARAGE_LXC_IDMAP="100000:100000"

GARAGE_ZONE="homelab"
GARAGE_CAPACITY="300G"

RESTIC_REPOSITORY="/mnt/backups/restic/garage-native"
RESTIC_PASSWORD_FILE="/root/.config/restic/garage-native.pass"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPNAME="backup-${STAMP}"

LOG_TAG="garage-zfs-init"
# --------------------------------------------------------------------------------

log() {
    echo "[$(date -Is)] $*"
    logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

WORKDIR="$(mktemp -d /tmp/garage-backup.XXXXXX)"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

log "=== Garage Instance Backup: ${STAMP} ==="

# Make sure the container itself is running.
if ! pct status "$CTID" | grep -q "status: running"; then
    echo "ERROR: LXC ${CTID} is not running."
    exit 1
fi

GARAGE_WAS_RUNNING=0

if pct exec "$CTID" -- systemctl is-active --quiet garage; then
    GARAGE_WAS_RUNNING=1
fi

restart_garage() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        echo "Restarting Garage after error..."
        pct exec "$CTID" -- systemctl start garage || true
    fi
}
trap 'restart_garage; cleanup' ERR INT TERM

if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
    echo "Creating Garage metadata snapshot..."
    pct exec "$CTID" -- garage meta snapshot
fi

if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
    echo "Stopping Garage..."
    pct exec "$CTID" -- systemctl stop garage
fi

log "Creating ZFS snapshots..."

zfs snapshot "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}"
zfs snapshot "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}"
zfs snapshot "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}"

if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
    echo "Starting Garage..."
    pct exec "$CTID" -- systemctl start garage
fi
trap cleanup EXIT

# Save data about garage
log "Saving Garage and LXC configuration..."

cp "/etc/pve/lxc/${CTID}.conf" \
   "${WORKDIR}/lxc-${CTID}.conf"

pct pull "$CTID" \
    /etc/garage.toml \
    "${WORKDIR}/garage.toml"

pct exec "$CTID" -- garage status \
    > "${WORKDIR}/garage-status.txt" || true

pct exec "$CTID" -- garage bucket list \
    > "${WORKDIR}/garage-buckets.txt" || true

pct exec "$CTID" -- garage key list \
    > "${WORKDIR}/garage-keys.txt" || true


export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

log "Backing up ZFS snapshots with restic..."

restic backup \
    "${GARAGE_META_ZFS_MOUNTPOINT}/.zfs/snapshot/${SNAPNAME}" \
    "${GARAGE_DATA_ZFS_MOUNTPOINT}/.zfs/snapshot/${SNAPNAME}" \
    "${GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT}/.zfs/snapshot/${SNAPNAME}" \
    "$WORKDIR" \
    --tag garage-instance \
    --tag "garage-${STAMP}"

log "Backup completed successfully."

log "Removing temporary ZFS snapshots..."

zfs destroy "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}"
zfs destroy "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}"
zfs destroy "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}"

log "=== Garage Instance Backup Complete ==="

# Group functions
# Install restic
# Deploy restic config