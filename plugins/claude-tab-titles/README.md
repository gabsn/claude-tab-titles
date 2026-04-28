# claude-tab-titles

A Claude Code plugin that turns your terminal tab title into a live status board for your Claude sessions.

| State | Tab title example |
| --- | --- |
| Working on your prompt | `Debug conductor app not launching` |
| Done, waiting for next prompt | `✅ Debug conductor app not launching` |
| Asking for permission / plan approval | `❓ Debug conductor app not launching` |

The session topic is auto-summarized from your first user message via Claude Haiku — so you can glance across a row of tabs and see which session is which without renaming anything by hand.

## Why

Running multiple Claude sessions in different tabs (worktrees, agents, side-quests) gets confusing fast. Default tab titles are just the working directory, which doesn't tell you which session is *waiting on you*, *done*, or *still working*.

## Install

```
/plugin marketplace add gabsn/claude-tab-titles
/plugin install claude-tab-titles@claude-tab-titles
```

That's it. Restart Claude Code (or run `/hooks` once) to pick up the new hooks.

## Compatibility

- **Terminal**: any modern terminal that honors OSC 0/2 escape sequences — Ghostty, iTerm2, Alacritty, kitty, WezTerm, Terminal.app, tmux. Tested primarily on Ghostty.
- **OS**: developed and tested on macOS. Should work on Linux without changes (the script is plain bash + `jq` + `claude`).
- **Dependencies**: `bash`, `jq`, and `claude` (the Claude Code CLI itself, used for the Haiku summary).

## How it works

Three hooks wired up in `hooks/hooks.json`:

- `Stop` → `title.sh set` → prefixes title with `✅`, starts a 10-minute background "keeper" loop that re-asserts the title every second so focus events can't strip the prefix.
- `UserPromptSubmit` → `title.sh clear` → drops the prefix back to plain topic. On the first prompt of a session, also kicks off a background `claude -p --model claude-haiku-4-5` call to summarize the message into a tab-friendly title, cached at `$TMPDIR/claude-title-<session_id>.txt`.
- `Notification` → `title.sh ask` → prefixes with `❓` and starts a keeper. Filtered: idle-style notifications (containing "waiting"/"idle"/"input" in the message) are treated as `set` instead, since Claude Code fires `Notification` for both real permission prompts and generic "your turn" alerts.

The keeper is a simple `( for _ in {1..600}; do sleep 1; printf '\033]0;...\007'; done ) &` subshell. It exits early if `/dev/tty` becomes unwritable (terminal closed) or when the next hook invocation `kill`s it via the per-PPID pidfile.

## Cost

One Haiku call per new session for the topic summary. Roughly **$0.0001** per session. Subsequent prompts in the same session reuse the cached title (no API call).

## Debugging

Set `CLAUDE_TAB_TITLES_DEBUG_LOG` to a file path to enable diagnostics:

```bash
export CLAUDE_TAB_TITLES_DEBUG_LOG=/tmp/claude-tab-titles.log
# tail the file while you work
tail -f /tmp/claude-tab-titles.log
```

## Known rough edges

- The `ask`-vs-`set` filter for `Notification` is a string-match heuristic. If your Claude Code version uses different wording for idle alerts, the filter may mis-classify. PRs welcome — the easiest path is to capture a few payloads via the debug log and tighten the filter.
- The Haiku summary is generated from the *first* user message and cached for the session. If your conversation pivots significantly, the title won't update. Delete the cache file to force regeneration: `rm $TMPDIR/claude-title-<session_id>.txt`.
- Background keepers persist for up to 10 minutes per Stop/Notification event. They self-clean when the terminal closes or when the next hook invocation kills them. If you somehow accumulate stragglers: `pkill -f title.sh`.

## License

MIT.
