#!/usr/bin/env bash
# Integration tests for claude-tab-titles.
# Hermetic: runs against a temp $TMPDIR, captures OSC writes to a file via
# CLAUDE_TAB_TITLES_TTY, and stubs `claude` with a fake binary on $PATH so the
# Haiku call never actually fires.
#
# Run: bash tests/test.sh
# Exit code: 0 on full pass, 1 on any failure.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugins/claude-tab-titles/scripts/title.sh"

WORK=$(mktemp -d)
cleanup() {
  for pf in "$WORK"/claude-title-keeper-*.pid; do
    [ -f "$pf" ] && kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- TAP-ish reporting --------------------------------------------------------

N=0; F=0; FAIL_NAMES=()
ok()      { N=$((N+1)); printf 'ok %d - %s\n' "$N" "$*"; }
not_ok()  { N=$((N+1)); F=$((F+1)); FAIL_NAMES+=("$*"); printf 'not ok %d - %s\n' "$N" "$*"; }

assert_contains() {
  local file=$1 needle=$2 desc=$3
  if grep -q "$needle" "$file" 2>/dev/null; then
    ok "$desc"
  else
    not_ok "$desc"
    [ -f "$file" ] && printf '  # captured (od -c | head):\n' && od -c "$file" | head -3 | sed 's/^/  # /'
  fi
}

assert_not_contains() {
  local file=$1 needle=$2 desc=$3
  if ! grep -q "$needle" "$file" 2>/dev/null; then
    ok "$desc"
  else
    not_ok "$desc"
  fi
}

# --- shared environment -------------------------------------------------------

# Stub `claude` so the Haiku call never goes out. The stub records the fact it
# was invoked into a marker file we can assert on.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<EOF
#!/bin/bash
echo "called" > "$WORK/claude-was-called"
# print nothing — real Haiku would echo a one-liner, but tests only care
# whether the stub ran.
EOF
chmod +x "$WORK/fakebin/claude"

# Real \`claude\` is needed for the validate tests at the very top, so we
# capture its full path before mutating PATH.
REAL_CLAUDE=$(command -v claude || true)

export TMPDIR="$WORK"
export CLAUDE_TAB_TITLES_NO_KEEPER=1     # default off; one test explicitly enables it
export PATH="$WORK/fakebin:$PATH"        # any `claude` from now on hits the stub

run_capture() {
  # $1 = mode, $2 = stdin JSON
  local mode=$1 input=$2 cap="$WORK/tty"
  : > "$cap"
  CLAUDE_TAB_TITLES_TTY="$cap" bash "$SCRIPT" "$mode" <<<"$input"
  printf '%s' "$cap"
}

echo "# claude-tab-titles tests"
echo "# script: $SCRIPT"
echo "# tmpdir: $WORK"

# --- 1. manifest validation ---------------------------------------------------

if [ -n "$REAL_CLAUDE" ]; then
  if "$REAL_CLAUDE" plugin validate "$ROOT/plugins/claude-tab-titles" >/dev/null 2>&1; then
    ok "plugin manifest validates (claude plugin validate)"
  else
    not_ok "plugin manifest validates (claude plugin validate)"
  fi
  if "$REAL_CLAUDE" plugin validate "$ROOT" >/dev/null 2>&1; then
    ok "marketplace manifest validates (claude plugin validate)"
  else
    not_ok "marketplace manifest validates (claude plugin validate)"
  fi
else
  ok "plugin manifest validates (skipped: no \`claude\` on PATH)"
  ok "marketplace manifest validates (skipped: no \`claude\` on PATH)"
fi

# --- 2. script syntax ---------------------------------------------------------

if bash -n "$SCRIPT" 2>/dev/null; then
  ok "title.sh: bash -n syntax check"
else
  not_ok "title.sh: bash -n syntax check"
fi

# --- 3. set mode --------------------------------------------------------------

CAP=$(run_capture set '{"session_id":"t-set","transcript_path":"/dev/null"}')
assert_contains "$CAP" $'\033]0;✅ ' "set: writes OSC 0 with ✅ prefix"
assert_contains "$CAP" $'\033]2;✅ ' "set: writes OSC 2 with ✅ prefix"

# --- 4. ask mode (real permission prompt) -------------------------------------

CAP=$(run_capture ask '{"session_id":"t-ask","message":"Claude needs your permission to use Edit"}')
assert_contains "$CAP"     $'\033]2;❓ ' "ask: real prompt → writes ❓"
assert_not_contains "$CAP" $'\033]2;✅ ' "ask: real prompt → no ✅"

# --- 5. ask mode (idle keyword falls through to set) --------------------------

CAP=$(run_capture ask '{"session_id":"t-idle","message":"Claude is waiting for your input"}')
assert_contains "$CAP"     $'\033]2;✅ ' "ask: idle wording → falls through to ✅"
assert_not_contains "$CAP" $'\033]2;❓ ' "ask: idle wording → no ❓"

# --- 6. clear mode ------------------------------------------------------------

CAP=$(run_capture clear '{"session_id":"t-clear","transcript_path":"/dev/null"}')
assert_not_contains "$CAP" $'\033]2;✅ ' "clear: no ✅ prefix"
assert_not_contains "$CAP" $'\033]2;❓ ' "clear: no ❓ prefix"
assert_contains     "$CAP" $'\033]2;'    "clear: still writes plain OSC 2"

# --- 7. cache reuse -----------------------------------------------------------

# Pre-populate the cache for session "cache-test"; set should pick it up.
echo -n "My Cool Topic" > "$WORK/claude-title-cache-test.txt"
CAP=$(run_capture set '{"session_id":"cache-test","transcript_path":"/dev/null"}')
assert_contains "$CAP" "✅ My Cool Topic" "set: uses cached title when present"

# --- 8. fallback to basename when no session_id ------------------------------

# Force PWD to a known basename for this test only.
HERE=$(pwd)
mkdir -p "$WORK/myproj" && cd "$WORK/myproj"
CAP=$(run_capture set '{}')
cd "$HERE"
assert_contains "$CAP" "✅ myproj" "set: no session_id → falls back to PWD basename"

# --- 9. PID file & keeper lifecycle ------------------------------------------

unset CLAUDE_TAB_TITLES_NO_KEEPER
: > "$WORK/tty"
CLAUDE_TAB_TITLES_TTY="$WORK/tty" bash "$SCRIPT" set <<<'{"session_id":"k1","transcript_path":"/dev/null"}'

# Pidfile should exist.
PIDFILE=$(ls "$WORK"/claude-title-keeper-*.pid 2>/dev/null | head -1)
if [ -n "$PIDFILE" ] && [ -s "$PIDFILE" ]; then
  ok "set: pidfile created with keeper PID"
else
  not_ok "set: pidfile created with keeper PID"
fi

# Keeper should be alive.
KPID=$(cat "$PIDFILE" 2>/dev/null || echo 0)
if kill -0 "$KPID" 2>/dev/null; then
  ok "set: keeper process is alive"
else
  not_ok "set: keeper process is alive"
fi

# Second invocation kills the previous keeper.
CLAUDE_TAB_TITLES_TTY="$WORK/tty" bash "$SCRIPT" set <<<'{"session_id":"k1","transcript_path":"/dev/null"}'
sleep 0.3
if ! kill -0 "$KPID" 2>/dev/null; then
  ok "set: subsequent invocation kills previous keeper"
else
  not_ok "set: subsequent invocation kills previous keeper"
  kill "$KPID" 2>/dev/null
fi

# Cleanup new keeper before next tests.
NEW_KPID=$(cat "$PIDFILE" 2>/dev/null || echo 0)
[ "$NEW_KPID" -gt 0 ] && kill "$NEW_KPID" 2>/dev/null
export CLAUDE_TAB_TITLES_NO_KEEPER=1

# --- 10. CLAUDE_TAB_TITLES_NO_KEEPER suppresses background loop --------------

# (covered indirectly above; explicit assertion: no pidfile when env var set)
rm -f "$WORK"/claude-title-keeper-*.pid
: > "$WORK/tty"
CLAUDE_TAB_TITLES_NO_KEEPER=1 \
CLAUDE_TAB_TITLES_TTY="$WORK/tty" \
bash "$SCRIPT" set <<<'{"session_id":"nokeeper","transcript_path":"/dev/null"}'
if [ -z "$(ls "$WORK"/claude-title-keeper-*.pid 2>/dev/null)" ]; then
  ok "NO_KEEPER=1: no pidfile created"
else
  not_ok "NO_KEEPER=1: no pidfile created"
fi

# --- 11. Haiku invocation gating (DISABLE_HAIKU env var) ---------------------

# Build a transcript with one user message so the haiku branch normally fires.
TRANSCRIPT="$WORK/transcript.jsonl"
echo '{"type":"user","message":{"role":"user","content":"please summarize this"}}' > "$TRANSCRIPT"

# Without DISABLE_HAIKU: stub claude should be invoked.
rm -f "$WORK/claude-was-called" "$WORK"/claude-title-haiku-*.txt
CLAUDE_TAB_TITLES_TTY="$WORK/tty" bash "$SCRIPT" clear \
  <<<"{\"session_id\":\"haiku-yes\",\"transcript_path\":\"$TRANSCRIPT\"}"
# Background subshell needs a moment to invoke the stub.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$WORK/claude-was-called" ] && break
  sleep 0.1
done
if [ -f "$WORK/claude-was-called" ]; then
  ok "clear without DISABLE_HAIKU: claude IS invoked"
else
  not_ok "clear without DISABLE_HAIKU: claude IS invoked"
fi

# With DISABLE_HAIKU: stub claude should NOT be invoked.
rm -f "$WORK/claude-was-called"
CLAUDE_TAB_TITLES_DISABLE_HAIKU=1 \
CLAUDE_TAB_TITLES_TTY="$WORK/tty" \
bash "$SCRIPT" clear <<<"{\"session_id\":\"haiku-no\",\"transcript_path\":\"$TRANSCRIPT\"}"
sleep 0.5
if [ ! -f "$WORK/claude-was-called" ]; then
  ok "clear with DISABLE_HAIKU=1: claude NOT invoked"
else
  not_ok "clear with DISABLE_HAIKU=1: claude NOT invoked"
fi

# --- 12. Robustness: empty stdin & missing transcript ------------------------

: > "$WORK/tty"
if CLAUDE_TAB_TITLES_TTY="$WORK/tty" bash "$SCRIPT" clear < /dev/null 2>/dev/null; then
  ok "clear with empty stdin: exits 0"
else
  not_ok "clear with empty stdin: exits 0"
fi

: > "$WORK/tty"
if CLAUDE_TAB_TITLES_TTY="$WORK/tty" bash "$SCRIPT" set < /dev/null 2>/dev/null; then
  ok "set with empty stdin: exits 0 (basename fallback)"
else
  not_ok "set with empty stdin: exits 0 (basename fallback)"
fi

# --- summary ------------------------------------------------------------------

echo "1..$N"
echo "# tests $N, failures $F"
if [ "$F" -gt 0 ]; then
  echo "# FAILED:"
  for n in "${FAIL_NAMES[@]}"; do echo "#   - $n"; done
  exit 1
fi
exit 0
