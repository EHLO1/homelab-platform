#!/usr/bin/env bash
#
# garage-zfs-init.sh
# - Creates ZFS datasets if they do not already exist
# - Mounts associated directories to Proxmox Garage LXC
# - Sets subuid/subgid ownership of mounted directories
# - Deploys garage configuration and initializes layout
# - Installs caddy with dns.providers.cloudflare module
# - Deploys caddy configuration
# - Idempotent
# - Doppler Secrets Manager is used to substitute secret values in template config
# 
# Intended to be used as the "Post-Install Hook" script that runs
# after the Garage Proxmox Community Script:
# https://community-scripts.org/scripts/garage

set -euo pipefail
umask 077

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

GARAGE_LXC_IDMAP="100000:100000"

GARAGE_ZONE="homelab"
GARAGE_CAPACITY="300G"

CONFIG_REPOSITORY="https://raw.githubusercontent.com/EHLO1/homelab-platform/main"
GARAGE_CONFIG_TEMPLATE="$CONFIG_REPOSITORY/garage/garage.toml.tmpl"
CADDY_CONFIG_TEMPLATE="$CONFIG_REPOSITORY/garage/Caddyfile.tmpl"

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

deploy_garage_config() {
    curl -fsSL "$GARAGE_CONFIG_TEMPLATE" -o ./garage.toml.tmpl
    RPC_SECRET_VALUE=$(openssl rand -hex 32) \
    METRICS_TOKEN_VALUE=$(openssl rand -hex 32) \
    envsubst '${RPC_SECRET_VALUE} ${METRICS_TOKEN_VALUE}' \
        < ./garage.toml.tmpl > ./garage.toml

    log "Copying garage.toml to LXC $CTID /etc/garage.toml"

    pct push $CTID ./garage.toml /etc/garage.toml --user root --group root --perms 600
    log "Garage config copied..."
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

initialize_garage_layout() {
    local node_id

    node_id=$(pct exec "$CTID" -- garage node id)
    node_id="${node_id%%@*}"

    log "Initializing Garage layout for node $node_id"

    pct exec "$CTID" -- \
        garage layout assign "$node_id" \
        -z "$GARAGE_ZONE" \
        -c "$GARAGE_CAPACITY"

    pct exec "$CTID" -- garage layout apply --version 1

    log "Garage layout initialized."
}

check_garage_status() {
    local status

    log "Checking Garage service..."

    if ! pct exec "$CTID" -- systemctl is-active --quiet garage.service; then
        pct exec "$CTID" -- systemctl --no-pager status garage.service || true
        die "Garage service is not running."
    fi

    log "Checking Garage layout..."

    status=$(pct exec "$CTID" -- garage status)

    if grep -q "NO ROLE ASSIGNED" <<<"$status"; then
        log "Garage node has no assigned role; initializing layout..."
        initialize_garage_layout

        # Verify initialization succeeded
        status=$(pct exec "$CTID" -- garage status)

        if grep -q "NO ROLE ASSIGNED" <<<"$status"; then
            die "Garage layout initialization failed."
        fi
    fi

    log "Garage is running and has a valid layout."
}

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

    log "Copying Caddyfile to LXC $CTID..."

    pct push "$CTID" ./Caddyfile /etc/caddy/Caddyfile \
        --user root \
        --group caddy \
        --perms 640

    log "Validating Caddy configuration..."

    if ! pct exec "$CTID" -- caddy validate --config /etc/caddy/Caddyfile; then
        die "Caddy configuration validation failed."
    fi

    log "Restarting Caddy..."
    pct exec "$CTID" -- systemctl restart caddy

    if ! pct exec "$CTID" -- systemctl is-active --quiet caddy.service; then
        pct exec "$CTID" -- systemctl --no-pager status caddy.service || true
        die "Caddy failed to start."
    fi

    log "Caddy is running successfully."
}

# Game Time ----------------------------------------------------------------------
WORKDIR=$(mktemp -d /run/garage-zfs-init.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

deploy_garage_config

log "Stopping LXC $CTID..."
pct shutdown $CTID

create_mounts

log "Stopping LXC $CTID..."
pct start $CTID

check_garage_status

install_caddy
deploy_caddy_config

log "Garage post-install setup complete."