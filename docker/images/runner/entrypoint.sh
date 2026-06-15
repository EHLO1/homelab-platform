#!/bin/bash
set -uo pipefail

# --- Options -----------------------------------------------------------------------
#  RUN_MODE          ansible | packer
#  CONTENT_REF       git ref of the content repo to run (ex: main)
#  CONTENT_REPO_URL  url of content repo
#  N8N_CALLBACK_URL  webhook n8n is listening on for the result
#  RUN_ID            opaque id n8n uses to correlate the result
#
#  RUN_MODE=ansible
#  - ANSIBLE_ARGS
#  - ANSIBLE_PLAYBOOK
#  
#  RUN_MODE=packer Args:   
#  - PACKER_TEMPLATE *required
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
          --arg target "${ANSIBLE_PLAYBOOK:-${PACKER_TEMPLATE:-}}" \
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

trap 'ec=$?; [ "$ec" -ne 0 ] && RC=$ec; report' EXIT
fail(){ RC="${2:-1}"; log "ERROR: $1"; exit "$RC"; }

: "${RUN_MODE:?set RUN_MODE to ansible or packer}"
: "${CONTENT_REPO_URL:?CONTENT_REPO_URL must be set (image default or per run)}"
CONTENT_REF="${CONTENT_REF:-main}"

# Load Doppler Service Token
if [ -f "/run/secrets/dp_runner_token" ]; then
    export DOPPLER_TOKEN=$(cat /run/secrets/dp_runner_token)
else
    echo "Error: dp_runner_token secret not found."
    exit 1
fi

# Prepare SSH keys
mkdir -p ~/.ssh
doppler run --command='printenv $RUNNER_SSH_KEY' > ~/.ssh/id_runner
chmod 600 ~/.ssh/id_runner

# Grab the Playbooks / Templates from Git
log "Pulling ${CONTENT_REPO_URL}@${CONTENT_REF}"
git clone --depth 1 --branch "$CONTENT_REF" "${CONTENT_REPO_URL}" "$CONTENT_DIR" >>"$LOG" 2>&1 \
  || fail "git clone failed (ref ${CONTENT_REF})" "$?"
cd "$CONTENT_DIR"

# Run
case "$RUN_MODE" in
  ansible)
    : "${ANSIBLE_PLAYBOOK:?ANSIBLE_PLAYBOOK required for ansible mode}"
    log "ansible-playbook $ANSIBLE_ARGS $ANSIBLE_PLAYBOOK"
    ansible-playbook "$ANSIBLE_ARGS" "$ANSIBLE_PLAYBOOK" 2>&1 | tee -a "$LOG"; RC=${PIPESTATUS[0]}
    ;;
  packer)
    : "${PACKER_TEMPLATE:?PACKER_TEMPLATE required for packer mode}"
    log "packer init $PACKER_TEMPLATE"
    packer init "$PACKER_TEMPLATE" 2>&1 | tee -a "$LOG"; RC=${PIPESTATUS[0]}
    if [ "$RC" -eq 0 ]; then
      vargs=(); [ -n "${PACKER_VARS:-}" ] && vargs+=(-var-file "$PACKER_VARS")
      log "packer build ${vargs[*]} $TEMPLATE"
      packer build "${vargs[@]}" "$TEMPLATE" 2>&1 | tee -a "$LOG"; RC=${PIPESTATUS[0]}
    fi
    ;;
  *)
    fail "unknown RUN_MODE '$RUN_MODE' (expected ansible|packer)"
    ;;
esac

exit "$RC"