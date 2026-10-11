#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

PHASE="${1:-}"
[[ -n "$PHASE" ]] || exit 0

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
HOOK_DIR="$SCRIPT_DIR/hooks.d"

for HOOK in "$HOOK_DIR"/*; do
    [[ -f "$HOOK" && -x "$HOOK" ]] || continue

    MODE="sync"
    PHASES=""

    # Read header comments, allowing blank lines
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" == \#* ]] || break

        case "$line" in
            '# mode:'*)
                MODE="${line#\# mode:}"
                MODE="${MODE//[[:space:]]/}"
                ;;
            '# phases:'*)
                PHASES="${line#\# phases:}"
                ;;
        esac
    done < "$HOOK"

    # Match phase
    MATCH=0

    for p in $PHASES; do
        if [[ "$p" == "$PHASE" ]]; then
            MATCH=1
            break
        fi
    done

    [[ "$MATCH" -eq 1 ]] || continue

    echo "[vzdump-hooks] $PHASE: $(basename "$HOOK") ($MODE)"

    # Execute hook
    case "$MODE" in
        sync)
            "$HOOK" "$@"
            ;;
        async)
            setsid "$HOOK" "$@" \
                >>/var/log/vzdump-async-hooks.log 2>&1 </dev/null &
            ;;
        *)
            echo "ERROR: Invalid mode '$MODE' in $HOOK" >&2
            exit 1
            ;;
    esac
done

exit 0