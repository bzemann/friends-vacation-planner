#!/usr/bin/env bash
# Fast checks run by the Claude Code hook after every Edit/Write.
# Silent on success (exit 0). On failure: errors to stderr, exit 2.
# Every check is skipped silently if its tool is not installed yet.

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}" || exit 0

failed=0
output=""

run_check() {
  local name="$1"; shift
  local out
  if ! out="$("$@" 2>&1)"; then
    output+=$'\n'"=== ${name} failed ==="$'\n'"${out}"$'\n'
    failed=1
  fi
}

BIN="node_modules/.bin"

[ -x "$BIN/prettier" ] && run_check "prettier" "$BIN/prettier" --check . --log-level warn
[ -x "$BIN/eslint" ]   && run_check "eslint" "$BIN/eslint" . --cache --max-warnings=0
[ -x "$BIN/tsc" ] && [ -f tsconfig.json ] && run_check "tsc" "$BIN/tsc" --noEmit --incremental

if command -v deno >/dev/null 2>&1; then
  shopt -s nullglob
  fns=(supabase/functions/*/index.ts)
  [ ${#fns[@]} -gt 0 ] && run_check "deno check" deno check "${fns[@]}"
fi

if [ "$failed" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  exit 2
fi
exit 0
