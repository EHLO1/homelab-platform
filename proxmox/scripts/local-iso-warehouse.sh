#!/usr/bin/env bash
#
# local-iso-warehouse.sh
# Keep a Proxmox ISO storage stocked with the latest release of a given
# distribution.
# 
# It's idempotent, AKA nothing is downloaded unless the release is newer.
#
# Example cron schedule:
#
# install -m 0755 local-iso-warehouse.sh /usr/local/sbin/local-iso-warehouse.sh
# /etc/cron.d/iso-warehouse  # Sundays at 0330
# 30 3 * * 0 root /usr/local/sbin/local-iso-warehouse.sh >> /var/log/iso-warehouse.log 2>&1
#
set -euo pipefail

# Config -------------------------------------------------------------------------
# TODO: Rework this to allow passing arguments for different distros and versions.
VERSION="26.04"
RELEASE_BASE="https://releases.ubuntu.com/${VERSION}"
SUMS_URL="${RELEASE_BASE}/SHA256SUMS"
ISO_SUFFIX="-live-server-amd64.iso"
PVE_STORAGE="vm1-storage"
STABLE_NAME="ubuntu-${VERSION}-live-server-amd64.iso"
ISO_DIR="/var/lib/vz/template/iso"
LOG_TAG="iso-warehouse"
# --------------------------------------------------------------------------------

log() { echo "[$(date -Is)] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }

command -v pvesm >/dev/null || die "pvesm not found"
command -v curl  >/dev/null || die "curl not found"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Fetch the upstream checksum manifest for the version.
log "Fetching ${SUMS_URL}"
curl -fsSL "$SUMS_URL" -o "$tmp" || die "could not fetch SHA256SUMS"

# Grab the live-server line. Typically, there's only one (the series dir
# holds only the current release); if several, take the highest version.
line="$(grep -E "\*ubuntu-${VERSION}(\.[0-9]+)?${ISO_SUFFIX}\$" "$tmp" \
        | sort -V | tail -n1)" || true
[ -n "$line" ] || die "no '${ISO_SUFFIX}' entry in SHA256SUMS for ${VERSION}"

upstream_hash="${line%% *}"
upstream_file="${line##*\*}"
upstream_url="${RELEASE_BASE}/${upstream_file}"
log "Latest upstream: ${upstream_file} (sha256 ${upstream_hash:0:12}…)"

# Compare against local
local_path="${ISO_DIR}/${STABLE_NAME}"
if [ -f "$local_path" ]; then
    log "Hashing existing ${STABLE_NAME} …"
    local_hash="$(sha256sum "$local_path" | awk '{print $1}')"
    if [ "$local_hash" = "$upstream_hash" ]; then
        log "Local ${STABLE_NAME} is already current. Nothing to do."
        exit 0
    fi
    log "Hash differs (have ${local_hash:0:12}…). Updating to ${upstream_file}."
    rm -f "$local_path"
else
    log "No existing ISO at ${local_path}. Downloading."
fi

# Tell Proxmox to download the ISO and verify the checksum
log "Downloading into ${PVE_STORAGE} as ${STABLE_NAME}"
pvesm download-url "$PVE_STORAGE" "$upstream_url" \
    --content iso \
    --filename "$STABLE_NAME" \
    --checksum "$upstream_hash" \
    --checksum-algorithm sha256

log "Done. Local ${STABLE_NAME} is updated."