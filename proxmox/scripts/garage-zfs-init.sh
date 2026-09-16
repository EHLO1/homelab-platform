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
GARAGE_META_ZFS_POOL="primary-pool"
GARAGE_DATA_ZFS_POOL="primary-pool"
GARAGE_SNAPSHOT_ZFS_POOL="primary-pool"

GARAGE_ZFS_MOUNTPOINT_ROOT="/mnt/garage"
GARAGE_LXC_MOUNTPOINT_ROOT="/var/lib/garage"

GARAGE_LXC_CONTAINER_ID="${CTID}"

# RELEASE_BASE="https://releases.ubuntu.com/${VERSION}"
# SUMS_URL="${RELEASE_BASE}/SHA256SUMS"
# ISO_SUFFIX="-live-server-amd64.iso"

# # Proxmox specific config
# PVE_NODE="$(hostname)" # Dynamically grabs the current node name
# PVE_STORAGE="local"

# ISO_DIR="/var/lib/vz/template/iso" 
# STABLE_NAME="ubuntu-${VERSION}-live-server-amd64.iso"
# LOG_TAG="iso-warehouse"
# # --------------------------------------------------------------------------------