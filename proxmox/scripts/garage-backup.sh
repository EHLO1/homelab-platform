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
GARAGE_META_ZFS_DATASET="primary-pool/garage/meta"
GARAGE_DATA_ZFS_DATASET="primary-pool/garage/data"
GARAGE_SNAPSHOTS_ZFS_DATASET="primary-pool/garage/snapshots"

GARAGE_META_ZFS_MOUNTPOINT="/mnt/garage/meta"
GARAGE_DATA_ZFS_MOUNTPOINT="/mnt/garage/data"
GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT="/mnt/garage/snapshots"

GARAGE_LXC_IDMAP="100000:100000"
GARAGE_LXC_NAME="lxc-garage-1"

GARAGE_ZONE="homelab"
GARAGE_CAPACITY="300G"

GARAGE_RESTIC_ZFS_DATASET="cold-storage-pool/restic/garage"
GARAGE_RESTIC_ZFS_MOUNTPOINT="/mnt/backups/restic/garage"
RESTIC_REPOSITORY="$GARAGE_RESTIC_ZFS_MOUNTPOINT"
RESTIC_GDRIVE_REPOSITORY="rclone:gdrive:restic/garage"
RESTIC_PASSWORD_FILE="/root/.config/restic/garage.pass"

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

ensure_restic_exists() {
    if [[ ! -f /etc/os-release ]]; then
        die "Unable to determine OS."
    fi

    . /etc/os-release

    if [[ "$ID" != "debian" ]]; then
        die "Unsupported OS: ${PRETTY_NAME:-unknown}. Debian is required."
    fi

    if command -v restic >/dev/null 2>&1; then
        return 0
    fi

    log "Restic not found, installing it now..."
    apt update
    apt install -y restic

    if ! command -v restic >/dev/null 2>&1; then
        die "Failed to install Restic."
    fi

    echo "Restic installed successfully."
}

create_zfs_dataset() {
    local dataset="$1"
    local mountpoint="$2"

    if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
        log "Creating ZFS dataset $dataset"
        zfs create -p -o mountpoint="$mountpoint" -o atime=off "$dataset"
    else
        log "ZFS dataset $dataset already exists"
        zfs set mountpoint="$mountpoint" "$dataset"
        zfs set atime=off "$dataset"
    fi
}

ensure_backup_mounts_exist() {
    # Create ZFS Datasets and set Mountpoints
    create_zfs_dataset "$GARAGE_RESTIC_ZFS_DATASET" "$GARAGE_RESTIC_ZFS_MOUNTPOINT"

    # Configure ZFS Tuning
    zfs set compression=lz4 "$GARAGE_RESTIC_ZFS_DATASET"

    log "ZFS datasets, mountpoints, and permissions applied successfully."
}

# Ensure CTID (VMID) exists and is running
ensure_garage_lxc_is_up() {
    [[ -n "$CTID" ]] ||
        die "ERROR: LXC '${GARAGE_LXC_NAME}' does not exist."

    [[ "$CT_STATUS" == "running" ]] ||
        die "ERROR: LXC '${GARAGE_LXC_NAME}' (${CTID}) is not running."
}

garage_service_check() {
    GARAGE_WAS_RUNNING=0
    if pct exec "$CTID" -- systemctl is-active --quiet garage; then
        export GARAGE_WAS_RUNNING=1
    fi
}

restart_garage() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        log "Restarting Garage after error..."
        pct exec "$CTID" -- systemctl start garage || true
    fi
}
trap 'restart_garage; cleanup' ERR INT TERM

garage_metadata_snapshot() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        log "Creating Garage metadata snapshot..."
        pct exec "$CTID" -- garage meta snapshot
    fi
}

stop_garage() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        log "Stopping Garage..."
        pct exec "$CTID" -- systemctl stop garage
    fi
}

create_temp_zfs_snapshots() {
    log "Creating ZFS snapshots..."
    zfs snapshot "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}"
    zfs snapshot "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}"
    zfs snapshot "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}"
}

start_garage() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        echo "Starting Garage..."
        pct exec "$CTID" -- systemctl start garage
    fi
}
trap cleanup EXIT

# Save data about garage
save_garage_config() {
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
}

backup_garage_data() {
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
}

remove_temp_zfs_snapshots() {
    log "Removing temporary ZFS snapshots..."
    zfs destroy "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}"
    zfs destroy "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}"
    zfs destroy "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}"
}



# Group functions
# Install restic
# Deploy restic config


# Get CTID (VMID) from GARAGE_LXC_NAME and status
read -r CTID CT_STATUS < <(
        pct list | awk -v name="$GARAGE_LXC_NAME" '$NF == name {print $1, $2; exit}'
)



log "=== Garage Instance Backup Complete ==="