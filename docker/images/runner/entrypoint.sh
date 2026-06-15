#!/bin/bash
# set -e vs set -euo pipefail vs set -uo pipefail?
set -e

# --- Options -----------------------------------------------------------------------
#  RUN_MODE          ansible | packer
#  CONTENT_REF       git ref of the content repo to run (ex: main)
#  CONTENT_REPO_URL  url of content repo
#  N8N_CALLBACK_URL  webhook n8n is listening on for the result
#  RUN_ID            opaque id n8n uses to correlate the result
#
#  RUN_MODE=ansible Args:
#  - PLAYBOOK
#  - INVENTORY || HOSTS
#  - LIMIT
#  - TAGS
#  - EXTRA_VARS
#  
#  RUN_MODE=packer Args:   
#  - TEMPLATE *required
#  - PACKER_VARS (path to a -var-file)
#  
#  Secrets:  
#  DOPPLER_TOKEN
# ----------------------------------------------------------------------------------

CONTENT_DIR=/work/content
LOG=/work/run.log
RUN_ID="${RUN_ID:-$(date +%s)-$$}"
RC=0
REPORTED=0
mkdir -p /work; : > "$LOG"

log(){ echo "[$(date -Is)] $*" | tee -a "$LOG" >&2; }

# Report back to caller (HTTP POST to Webhook)
report(){
  [ "$REPORTED" = 1 ] && return 0; REPORTED=1
  local status; [ "$RC" -eq 0 ] && status=success || status=failed
  local summary
  summary="$(grep -E 'PLAY RECAP|ok=[0-9]|failed=[0-9]|unreachable=[0-9]|Build .* finished|[Ee]rror' "$LOG" | tail -n 25)"
  [ -n "$summary" ] || summary="$(tail -n 30 "$LOG")"
  if [ -n "${REPORT_CALLBACK_URL:-}" ]; then
    jq -n --arg run_id "$RUN_ID" --arg mode "${RUN_MODE:-}" \
          --arg ref "${CONTENT_REF:-main}" \
          --arg target "${PLAYBOOK:-${TEMPLATE:-}}" \
          --arg status "$status" --argjson exit_code "$RC" \
          --arg summary "$summary" \
          '{run_id:$run_id, mode:$mode, ref:$ref, target:$target, status:$status, exit_code:$exit_code, summary:$summary}' \
      | curl -fsS -X POST "$REPORT_CALLBACK_URL" -H 'Content-Type: application/json' --data @- \
      && log "Reported '$status' to n8n (run $RUN_ID)" \
      || log "WARNING: could not POST result to n8n"
  else
    log "No REPORT_CALLBACK_URL set; final status '$status' (rc=$RC)"
  fi
}
# Adopt the real exit status if RC wasn't set explicitly (e.g. a :? validation trip).
trap 'ec=$?; [ "$ec" -ne 0 ] && RC=$ec; report' EXIT
fail(){ RC="${2:-1}"; log "ERROR: $1"; exit "$RC"; }

: "${RUN_MODE:?set RUN_MODE to ansible or packer}"
: "${CONTENT_REPO_URL:?CONTENT_REPO_URL must be set (image default or per run)}"
CONTENT_REF="${CONTENT_REF:-main}"

# Load Doppler Service Token
if [ -f "/run/secrets/dp_ansible_token" ]; then
    export DOPPLER_TOKEN=$(cat /run/secrets/dp_ansible_token)
else
    echo "Error: dp_ansible_token secret not found."
    exit 1
fi

# Prepare SSH keys
mkdir -p ~/.ssh
doppler run --command='printenv $RUNNER_SSH_KEY' > ~/.ssh/id_runner
chmod 600 ~/.ssh/id_runner

# Handle Inventory Override
HAS_INVENTORY=false
for arg in "$@"; do
    if [[ "$arg" == "-i" ]] || [[ "$arg" == "--inventory" ]] || [[ "$arg" == "--inventory-file" ]]; then
        HAS_INVENTORY=true
        break
    fi
done

# Execute Ansible with Proxmox Dynamic Inventory Default
if [ "$HAS_INVENTORY" = true ]; then
    echo "Executing playbook with user-supplied inventory target..."
    exec doppler run -- ansible-playbook "$@"
else
    echo "Executing playbook with Proxmox dynamic inventory..."
    exec doppler run -- ansible-playbook -i proxmox.yml "$@"
fi