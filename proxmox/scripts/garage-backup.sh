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

RESTIC_LOCAL_REPOSITORY="$GARAGE_RESTIC_ZFS_MOUNTPOINT"
RESTIC_GDRIVE_REPOSITORY="rclone:gdrive:restic/garage"
RESTIC_PASSWORD_FILE="/root/.config/restic/garage.pass"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPNAME="backup-${STAMP}"

LOG_TAG="garage-backup"
# --------------------------------------------------------------------------------

log() {
    echo "[$(date -Is)] $*"
    logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

WORKDIR="$(mktemp -d /run/garage-backup.XXXXXX)"
CTID=""
CT_STATUS=""
GARAGE_WAS_RUNNING=0
GARAGE_STOPPED_BY_SCRIPT=0
ZFS_SNAPSHOTS_CREATED=0

cleanup() {
    local rc=$?

    # Prevent "exit" below from invoking this trap again.
    trap - EXIT
    set +e

    if [[ "$GARAGE_STOPPED_BY_SCRIPT" -eq 1 ]]; then
        log "Starting Garage after interrupted backup..."
        pct exec "$CTID" -- systemctl start garage
    fi

    if [[ "$ZFS_SNAPSHOTS_CREATED" -eq 1 ]]; then
        log "Removing temporary ZFS snapshots after interrupted backup..."

        zfs destroy "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}" 2>/dev/null || true
        zfs destroy "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}" 2>/dev/null || true
        zfs destroy "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}" 2>/dev/null || true
    fi

    rm -rf "$WORKDIR"

    exit "$rc"
}

trap cleanup EXIT

log "=== Garage Instance Backup: ${STAMP} ==="

# 1
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

    log "restic not found, installing it now..."
    apt update
    apt install -y restic

    if ! command -v restic >/dev/null 2>&1; then
        die "Failed to install restic."
    fi

    log "restic installed successfully."
}

# 2
ensure_rclone_exists() {
    if command -v rclone >/dev/null 2>&1; then
        return 0
    fi

    log "rclone not found, installing it now..."
    apt update
    apt install -y rclone

    if ! command -v rclone >/dev/null 2>&1; then
        die "Failed to install rclone."
    fi

    log "rclone installed successfully."
}

# 3
check_restic_credentials() {
    [[ -s "$RESTIC_PASSWORD_FILE" ]] ||
        die "Restic password file does not exist: $RESTIC_PASSWORD_FILE"

    chmod 600 "$RESTIC_PASSWORD_FILE"

    log "Checking Google Drive access..."

    if ! rclone lsd gdrive: >/dev/null; then
        die "Unable to access Google Drive through rclone remote 'gdrive:'."
    fi

    log "Google Drive access confirmed."
}

# Helper
restic_repository_exists() {
    local repository="$1"
    local rc=0

    restic -r "$repository" cat config >/dev/null 2>&1 || rc=$?

    case "$rc" in
        0)
            return 0
            ;;
        10)
            return 1
            ;;
        *)
            die "Unable to access restic repository '$repository' (exit code $rc)."
            ;;
    esac
}

# Helper
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

# 4
ensure_backup_mounts_exist() {
    create_zfs_dataset \
        "$GARAGE_RESTIC_ZFS_DATASET" \
        "$GARAGE_RESTIC_ZFS_MOUNTPOINT"

    zfs set compression=lz4 "$GARAGE_RESTIC_ZFS_DATASET"

    if ! mountpoint -q "$GARAGE_RESTIC_ZFS_MOUNTPOINT"; then
        log "Backup dataset is not mounted; mounting it..."
        zfs mount "$GARAGE_RESTIC_ZFS_DATASET"
    fi

    mountpoint -q "$GARAGE_RESTIC_ZFS_MOUNTPOINT" ||
        die "Backup dataset is not mounted at $GARAGE_RESTIC_ZFS_MOUNTPOINT."
}

# 5
initialize_restic_repositories() {
    export RESTIC_PASSWORD_FILE

    # Local
    if restic_repository_exists "$RESTIC_LOCAL_REPOSITORY"; then
        log "Local repository already initialized."
    else
        log "Initializing local repository..."

        restic \
            -r "$RESTIC_LOCAL_REPOSITORY" \
            init

        log "Local repository initialized."
    fi

    # Google Drive
    if restic_repository_exists "$RESTIC_GDRIVE_REPOSITORY"; then
        log "Google Drive repository already initialized."
    else
        log "Initializing Google Drive repository..."

        RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
        restic \
            -r "$RESTIC_GDRIVE_REPOSITORY" \
            init \
            --from-repo "$RESTIC_LOCAL_REPOSITORY" \
            --copy-chunker-params

        log "Google Drive repository initialized."
    fi
}

# 6
# Ensure CTID (VMID) exists and is running
ensure_garage_lxc_is_up() {
    [[ -n "$CTID" ]] ||
        die "LXC '${GARAGE_LXC_NAME}' does not exist."

    [[ "$CT_STATUS" == "running" ]] ||
        die "LXC '${GARAGE_LXC_NAME}' (${CTID}) is not running."
}

# 7
garage_service_check() {
    if pct exec "$CTID" -- systemctl is-active --quiet garage; then
        GARAGE_WAS_RUNNING=1
    fi
}

# 8
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

# 9
garage_metadata_snapshot() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        log "Creating Garage metadata snapshot..."
        pct exec "$CTID" -- garage meta snapshot
    fi
}

# 10
stop_garage() {
    if [[ "$GARAGE_WAS_RUNNING" -eq 1 ]]; then
        log "Stopping Garage..."
        pct exec "$CTID" -- systemctl stop garage
        GARAGE_STOPPED_BY_SCRIPT=1
    fi
}

# 11
create_temp_zfs_snapshots() {
    log "Creating ZFS snapshots..."

    zfs snapshot \
        "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}" \
        "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}" \
        "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}"

    ZFS_SNAPSHOTS_CREATED=1
}

# 12
start_garage() {
    if [[ "$GARAGE_STOPPED_BY_SCRIPT" -eq 1 ]]; then
        log "Starting Garage..."
        pct exec "$CTID" -- systemctl start garage
        GARAGE_STOPPED_BY_SCRIPT=0
    fi
}

# 13
backup_garage_data() {
    log "Backing up Garage ZFS snapshots to local repository..."

    restic \
        -r "$RESTIC_LOCAL_REPOSITORY" \
        backup \
        "${GARAGE_META_ZFS_MOUNTPOINT}/.zfs/snapshot/${SNAPNAME}" \
        "${GARAGE_DATA_ZFS_MOUNTPOINT}/.zfs/snapshot/${SNAPNAME}" \
        "${GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT}/.zfs/snapshot/${SNAPNAME}" \
        "$WORKDIR" \
        --host "$GARAGE_LXC_NAME" \
        --tag garage-instance \
        --tag "garage-${STAMP}"

    log "Local Garage backup completed successfully."

    log "Copying Garage backup to Google Drive..."

    RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic \
        -r "$RESTIC_GDRIVE_REPOSITORY" \
        copy \
        --from-repo "$RESTIC_LOCAL_REPOSITORY" \
        --tag "garage-${STAMP}"

    log "Google Drive backup completed successfully."
}

# 14
remove_temp_zfs_snapshots() {
    log "Removing temporary ZFS snapshots..."

    zfs destroy "${GARAGE_META_ZFS_DATASET}@${SNAPNAME}"
    zfs destroy "${GARAGE_DATA_ZFS_DATASET}@${SNAPNAME}"
    zfs destroy "${GARAGE_SNAPSHOTS_ZFS_DATASET}@${SNAPNAME}"

    ZFS_SNAPSHOTS_CREATED=0
}

# Get CTID (VMID) from GARAGE_LXC_NAME and status -------------------------------
read -r CTID CT_STATUS < <(
    pct list |
        awk -v name="$GARAGE_LXC_NAME" '$NF == name {print $1, $2; exit}'
) || true


# Preconditions ------------------------------------------------------------------
ensure_restic_exists
ensure_rclone_exists
check_restic_credentials

ensure_backup_mounts_exist

initialize_restic_repositories

ensure_garage_lxc_is_up


# Capture Garage -----------------------------------------------------------------
garage_service_check

save_garage_config

garage_metadata_snapshot

stop_garage
create_temp_zfs_snapshots
start_garage


# Backup -------------------------------------------------------------------------
backup_garage_data

remove_temp_zfs_snapshots


log "=== Garage Instance Backup Complete ==="