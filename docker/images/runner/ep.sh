#!/usr/bin/env bash
# entrypoint.sh — toolbox runner.
# Pulls content (playbooks / packer configs) from the infra-automation repo,
# runs the requested job, and ALWAYS reports the outcome back to n8n.
set -uo pipefail

# ── Contract (set by n8n when it creates the container) ──────────────────────
#   RUN_MODE          ansible | packer                              (required)
#   CONTENT_REF       git ref of the content repo to run            (default: main)
#   N8N_CALLBACK_URL  webhook n8n is listening on for the result
#   RUN_ID            opaque id n8n uses to correlate the result
#   Ansible:  PLAYBOOK (req); INVENTORY *or* HOSTS; LIMIT; TAGS; EXTRA_VARS
#   Packer:   TEMPLATE (req); PACKER_VARS (path to a -var-file)
#   Secrets:  DOPPLER_TOKEN (service token) — used to pull everything else
#   CONTENT_REPO_URL  baked into the image; override per run only if needed
# ─────────────────────────────────────────────────────────────────────────────

CONTENT_DIR=/work/content
LOG=/work/run.log
RUN_ID="${RUN_ID:-$(date +%s)-$$}"
RC=0
REPORTED=0
mkdir -p /work; : > "$LOG"

log(){ echo "[$(date -Is)] $*" | tee -a "$LOG" >&2; }

# Fires on EVERY exit path — validation failure, clone failure, run failure,
# or success — so n8n always hears back instead of timing out on silence.
report(){
  [ "$REPORTED" = 1 ] && return 0; REPORTED=1
  local status; [ "$RC" -eq 0 ] && status=success || status=failed
  local summary
  summary="$(grep -E 'PLAY RECAP|ok=[0-9]|failed=[0-9]|unreachable=[0-9]|Build .* finished|[Ee]rror' "$LOG" | tail -n 25)"
  [ -n "$summary" ] || summary="$(tail -n 30 "$LOG")"
  if [ -n "${N8N_CALLBACK_URL:-}" ]; then
    jq -n --arg run_id "$RUN_ID" --arg mode "${RUN_MODE:-}" \
          --arg ref "${CONTENT_REF:-main}" \
          --arg target "${PLAYBOOK:-${TEMPLATE:-}}" \
          --arg status "$status" --argjson exit_code "$RC" \
          --arg summary "$summary" \
          '{run_id:$run_id, mode:$mode, ref:$ref, target:$target, status:$status, exit_code:$exit_code, summary:$summary}' \
      | curl -fsS -X POST "$N8N_CALLBACK_URL" -H 'Content-Type: application/json' --data @- \
      && log "Reported '$status' to n8n (run $RUN_ID)" \
      || log "WARNING: could not POST result to n8n"
  else
    log "No N8N_CALLBACK_URL set; final status '$status' (rc=$RC)"
  fi
}
# Adopt the real exit status if RC wasn't set explicitly (e.g. a :? validation trip).
trap 'ec=$?; [ "$ec" -ne 0 ] && RC=$ec; report' EXIT
fail(){ RC="${2:-1}"; log "ERROR: $1"; exit "$RC"; }

: "${RUN_MODE:?set RUN_MODE to ansible or packer}"
: "${CONTENT_REPO_URL:?CONTENT_REPO_URL must be set (image default or per run)}"
CONTENT_REF="${CONTENT_REF:-main}"

# ── Load secrets from Doppler (Proxmox token, SSH key, repo token, vault pw…) ─
if [ -n "${DOPPLER_TOKEN:-}" ]; then
  log "Loading secrets from Doppler"
  if doppler secrets download --no-file --format env > /work/.secrets 2>>"$LOG"; then
    set -a; . /work/.secrets; set +a; rm -f /work/.secrets
  else
    fail "Doppler secret download failed"
  fi
fi

# Materialise an SSH key for Ansible if one was provided via Doppler.
if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  printf '%s\n' "$SSH_PRIVATE_KEY" > "$HOME/.ssh/id_runner"; chmod 600 "$HOME/.ssh/id_runner"
  export ANSIBLE_PRIVATE_KEY_FILE="$HOME/.ssh/id_runner"
fi

# ── Fetch the cartridge: content repo at the requested ref ───────────────────
clone_url="$CONTENT_REPO_URL"
[ -n "${CONTENT_REPO_TOKEN:-}" ] && \
  clone_url="$(printf '%s' "$CONTENT_REPO_URL" | sed -E "s#https://#https://x-access-token:${CONTENT_REPO_TOKEN}@#")"
log "Fetching ${CONTENT_REPO_URL}@${CONTENT_REF}"
git clone --depth 1 --branch "$CONTENT_REF" "$clone_url" "$CONTENT_DIR" >>"$LOG" 2>&1 \
  || fail "git clone failed (ref ${CONTENT_REF})" "$?"
cd "$CONTENT_DIR"

# ── Run ──────────────────────────────────────────────────────────────────────
case "$RUN_MODE" in
  ansible)
    : "${PLAYBOOK:?PLAYBOOK required for ansible mode}"
    args=()
    if [ -n "${HOSTS:-}" ]; then
      args+=(-i "${HOSTS%,},")                       # inline ad-hoc host list (trailing comma)
    else
      args+=(-i "${INVENTORY:?INVENTORY or HOSTS required}")
    fi
    [ -n "${LIMIT:-}" ]      && args+=(--limit "$LIMIT")
    [ -n "${TAGS:-}" ]       && args+=(--tags "$TAGS")
    [ -n "${EXTRA_VARS:-}" ] && args+=(-e "$EXTRA_VARS")
    log "ansible-playbook ${args[*]} $PLAYBOOK"
    ansible-playbook "${args[@]}" "$PLAYBOOK" 2>&1 | tee -a "$LOG"; RC=${PIPESTATUS[0]}
    ;;
  packer)
    : "${TEMPLATE:?TEMPLATE required for packer mode}"
    log "packer init $TEMPLATE"
    packer init "$TEMPLATE" 2>&1 | tee -a "$LOG"; RC=${PIPESTATUS[0]}
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