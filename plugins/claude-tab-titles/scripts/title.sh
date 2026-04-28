#!/bin/bash
# claude-tab-titles
# Updates the terminal tab title via OSC 0/2 escape sequences as Claude Code's
# state changes. Three modes: set (✅ idle), ask (❓ waiting), clear (working).
#
# Compatible with any terminal that honors OSC 0/2 (Ghostty, iTerm2, kitty,
# WezTerm, Alacritty, Terminal.app, tmux, …).

mode=$1

CACHE_DIR="${TMPDIR:-/tmp}"
PIDFILE="$CACHE_DIR/claude-title-keeper-$PPID.pid"
LOG="${CLAUDE_TAB_TITLES_DEBUG_LOG:-}"

log() {
  [ -n "$LOG" ] || return 0
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"
}

input=""
if [ ! -t 0 ]; then
  input=$(cat)
fi
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

basename=${PWD##*/}
basename=${basename:-Claude}
CACHE=""
[ -n "$session_id" ] && CACHE="$CACHE_DIR/claude-title-${session_id}.txt"

# Heuristic: Notification fires for both permission prompts AND idle "your turn"
# alerts. Treat idle-style messages as a Stop signal so we show ✅ instead of ❓.
# Adjust if your notifications speak differently.
if [ "$mode" = "ask" ]; then
  msg=$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)
  case "$msg" in
    *waiting*|*idle*|*input*) mode=set ;;
  esac
fi

case "$mode" in
  set)   prefix="✅ " ;;
  ask)   prefix="❓ " ;;
  clear) prefix="" ;;
  *)     prefix="" ;;
esac

read_title() {
  if [ -n "$CACHE" ] && [ -s "$CACHE" ]; then
    head -c 50 "$CACHE" | tr -d '\n'
  else
    printf '%s' "$basename"
  fi
}

write_title() {
  { printf '\033]0;%s\007\033]2;%s\007' "$1" "$1" >/dev/tty; } 2>/dev/null
}

# Kill any previous keeper so only one is running per Claude process.
if [ -f "$PIDFILE" ]; then
  oldpid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$oldpid" ] && kill "$oldpid" 2>/dev/null
  rm -f "$PIDFILE"
fi

write_title "${prefix}$(read_title)"

# For sticky states (idle / waiting), spawn a keeper that re-asserts the title
# every second for up to 10 minutes. Without it, Claude Code's own auto-titling
# strips our prefix on focus events. The keeper exits when /dev/tty is no longer
# writable (e.g. terminal closed) or when killed by the next hook invocation.
if [ "$mode" = "set" ] || [ "$mode" = "ask" ]; then
  (
    for _ in $(seq 1 600); do
      sleep 1
      cur="${prefix}$(read_title)"
      write_title "$cur" || break
    done
  ) >/dev/null 2>&1 &
  echo "$!" > "$PIDFILE"
  log "$mode keeper=$! title='${prefix}$(read_title)'"
else
  log "$mode title='${prefix}$(read_title)'"
fi

# On the first prompt of a session, kick off a Haiku call in the background to
# summarize the user's first message into a tab-friendly title (<50 chars).
# The keeper picks up the cached title on its next iteration. Cost: one Haiku
# call per session (~$0.0001).
if [ "$mode" = "clear" ] && [ -n "$CACHE" ] && [ ! -s "$CACHE" ] && [ -f "$transcript_path" ]; then
  first_msg=$(jq -rs '
    map(select(.message.role == "user" and (.message.content | type == "string")))
    | .[0].message.content // empty
  ' "$transcript_path" 2>/dev/null | head -c 2000)
  if [ -n "$first_msg" ]; then
    log "kicking off haiku for session=$session_id"
    (
      short=$(printf '%s' "$first_msg" | claude -p \
        "Summarize this user request as a short tab title under 45 characters. No quotes, no period, no markdown — just the title text on one line." \
        --model claude-haiku-4-5 2>/dev/null | head -1 | head -c 50 | tr -d '\n')
      if [ -n "$short" ]; then
        printf '%s' "$short" > "$CACHE"
        log "haiku done session=$session_id title='$short'"
      fi
    ) >/dev/null 2>&1 &
  fi
fi
