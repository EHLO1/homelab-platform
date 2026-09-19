#!/usr/bin/env bash
#
# garage-zfs-init.sh
# - Creates ZFS datasets if they do not already exist
# - Mounts associated directories to Proxmox Garage LXC
# - Sets subuid/subgid ownership of mounted directories
# - Idempotent
# 
# Intended to be used as the "Post-Install Hook" script that runs
# after the Garage Proxmox Community Script:
# https://community-scripts.org/scripts/garage

set -euo pipefail

# Config -------------------------------------------------------------------------
GARAGE_META_ZFS_DATASET="primary-pool/garage/meta"
GARAGE_DATA_ZFS_DATASET="primary-pool/garage/data"
GARAGE_SNAPSHOTS_ZFS_DATASET="primary-pool/garage/snapshots"

GARAGE_META_ZFS_MOUNTPOINT="/mnt/garage/meta"
GARAGE_DATA_ZFS_MOUNTPOINT="/mnt/garage/data"
GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT="/mnt/garage/snapshots"

GARAGE_META_LXC_MOUNTPOINT="/var/lib/garage/meta"
GARAGE_DATA_LXC_MOUNTPOINT="/var/lib/garage/data"
GARAGE_SNAPSHOTS_LXC_MOUNTPOINT="/var/lib/garage/snapshots"

GARAGE_LXC_CONTAINER_ID="$CTID"

GARAGE_LXC_IDMAP="100000:100000"

CONFIG_REPOSITORY="https://www.github.com/EHLO1/homelab-platform/main"
GARAGE_CONFIG_TEMPLATE="$CONFIG_REPOSITORY/garage/garage.toml.tmpl"
CADDY_CONFIG_TEMPLATE=$(curl -fsSL "$CONFIG_REPOSITORY/garage/Caddyfile")

LOG_TAG="garage-zfs-init"
# --------------------------------------------------------------------------------

log() { echo "[$(date -Is)] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }

# Overwrite default Garage config
deploy_garage_config() {
    curl -fsSL "$GARAGE_CONFIG_TEMPLATE" -o ./garage.toml.tmpl
    doppler secrets substitute ./garage.toml.tmpl > ./garage.toml

    log "Copying garage.toml to LXC $CTID /etc/garage.toml"

    pct push $CTID ./garage.toml /etc/garage.toml --user root --group root --perms 600
    log "garage config copied..."
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

create_mounts() {
    # Create ZFS Datasets and set Mountpoints
    create_zfs_dataset "$GARAGE_META_ZFS_DATASET" "$GARAGE_META_ZFS_MOUNTPOINT"
    create_zfs_dataset "$GARAGE_DATA_ZFS_DATASET" "$GARAGE_DATA_ZFS_MOUNTPOINT"
    create_zfs_dataset "$GARAGE_SNAPSHOTS_ZFS_DATASET" "$GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT"

    # Configure ZFS Tuning
    zfs set compression=lz4 "$GARAGE_META_ZFS_DATASET"
    zfs set recordsize=16K "$GARAGE_META_ZFS_DATASET"

    zfs set compression=lz4 "$GARAGE_DATA_ZFS_DATASET"
    zfs set recordsize=1M "$GARAGE_DATA_ZFS_DATASET"

    zfs set compression=lz4 "$GARAGE_SNAPSHOTS_ZFS_DATASET"

    # Change owner to LXC's subuid/subgid
    chown "$GARAGE_LXC_IDMAP" "$GARAGE_META_ZFS_MOUNTPOINT" "$GARAGE_DATA_ZFS_MOUNTPOINT" "$GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT"

    # Mount to LXC
    pct set $CTID -mp0 "$GARAGE_META_ZFS_MOUNTPOINT",mp="$GARAGE_META_LXC_MOUNTPOINT"
    pct set $CTID -mp1 "$GARAGE_DATA_ZFS_MOUNTPOINT",mp="$GARAGE_DATA_LXC_MOUNTPOINT"
    pct set $CTID -mp2 "$GARAGE_SNAPSHOTS_ZFS_MOUNTPOINT",mp="$GARAGE_SNAPSHOTS_LXC_MOUNTPOINT"
    log "ZFS datasets, mountpoints, and permissions applied successfully."
}

check_garage_status() {
    # TODO: Add check to pct exec and get the garage systemd service status before continuing
    pct exec $CTID -- systemctl status garage.service
    # Verify Garage status
    # TODO: Turn this into a conditional check (Check for an ID)
    pct exec $CTID -- garage status
    log "garage is running, responding, and has a valid layout."
}

# Install Caddy with Module dns.providers.cloudflare
install_caddy() {
    log "Installing Caddy..."

    pct exec "$CTID" -- bash -s <<'EOF'
set -euo pipefail

apt install -y \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https \
    curl \
    gnupg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list

apt update
apt install -y caddy

curl -fsSL \
    'https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/caddy-dns/cloudflare' \
    -o /tmp/caddy.custom

chmod 0755 /tmp/caddy.custom

if ! dpkg-divert --list /usr/bin/caddy | grep -q '/usr/bin/caddy.default'; then
    dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy
fi

mv /tmp/caddy.custom /usr/bin/caddy.custom

update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50
EOF

    log "Caddy install successful."
}

deploy_caddy_config() {
    curl -fsSL "$CADDY_CONFIG_TEMPLATE" -o ./Caddyfile.tmpl
    doppler secrets substitute ./Caddyfile.tmpl > ./Caddyfile

    # Deploy Caddyfile
    log "Copying Caddyfile to LXC $CTID /etc/caddy/Caddyfile"

    pct push "$CTID" ./Caddyfile /etc/caddy/Caddyfile \
    --user root \
    --group caddy \
    --perms 640

    log "Caddyfile copied, restarting caddy..."
    pct exec $CTID -- systemctl restart caddy
    # TODO: Turn this into a conditional check (Check for running/healthy, etc..)
    pct exec $CTID -- systemctl status caddy.service
    log "caddy restart successful and status is running."
}

# Game time
# ------------

mkdir -p /run/garage-zfs-init && cd /run/garage-zfs-init
deploy_garage_config
pct shutdown $CTID
create_mounts
pct start $CTID
check_garage_status
install_caddy
deploy_caddy_config
rm -rf /run/garage-zfs-init