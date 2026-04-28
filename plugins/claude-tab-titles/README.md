# claude-tab-titles

[![tests](https://github.com/gabsn/claude-tab-titles/actions/workflows/test.yml/badge.svg)](https://github.com/gabsn/claude-tab-titles/actions/workflows/test.yml)

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

Or from the CLI:

```bash
claude plugin marketplace add gabsn/claude-tab-titles
claude plugin install claude-tab-titles@claude-tab-titles
```

Restart Claude Code (or run `/hooks` once) to activate the hooks. New tabs you start after that will show the status indicators.

## Prerequisites

- **Claude Code** ≥ 2.1 (plugin system).
- **`jq`** in `PATH` — used to parse hook input and the session transcript.
  - macOS: `brew install jq` · Debian/Ubuntu: `apt install jq` · Fedora: `dnf install jq`.
- **`claude` CLI** in `PATH` — used to summarize your first message via Haiku. (You already have this if you're using Claude Code.)
- **A terminal that honors OSC 0/2** — Ghostty, iTerm2, kitty, WezTerm, Alacritty, Terminal.app, and most others. tmux works if `set-option -g allow-rename on` is set (default on most distros).

If `jq` is missing the title falls back to the directory basename (no crash, just no Haiku summary). If `claude` is missing the Haiku summary is skipped silently.

## Migrating from a manual install

If you previously copied a script into `~/.claude/hooks/` and wired up Stop/UserPromptSubmit/Notification hooks by hand in `~/.claude/settings.json`, **remove those manual entries before installing this plugin** — otherwise both will fire and fight over the title (no visual harm, but two keepers per state).

In `~/.claude/settings.json`, delete the manual command entries from `hooks.Stop`, `hooks.UserPromptSubmit`, and `hooks.Notification` that point to your hand-rolled script. Anything else in those arrays (e.g. an `afplay` sound) can stay.

## How it works

Three hooks wired up in `hooks/hooks.json`:

- `Stop` → `title.sh set` → prefixes title with `✅`, starts a 10-minute background "keeper" loop that re-asserts the title every second so focus events can't strip the prefix.
- `UserPromptSubmit` → `title.sh clear` → drops the prefix back to plain topic. On the first prompt of a session, also kicks off a background `claude -p --model claude-haiku-4-5` call to summarize the message into a tab-friendly title, cached at `$TMPDIR/claude-title-<session_id>.txt`.
- `Notification` → `title.sh ask` → prefixes with `❓` and starts a keeper. Filtered: idle-style notifications (containing "waiting"/"idle"/"input" in the message) are treated as `set` instead, since Claude Code fires `Notification` for both real permission prompts and generic "your turn" alerts.

The keeper is a simple `( for _ in {1..600}; do sleep 1; printf '\033]0;...\007'; done ) &` subshell. It exits early if `/dev/tty` becomes unwritable (terminal closed) or when the next hook invocation `kill`s it via the per-PPID pidfile.

## Cost

One Haiku call per new session for the topic summary. Roughly **$0.0001** per session. Subsequent prompts in the same session reuse the cached title (no API call). Set `CLAUDE_TAB_TITLES_DISABLE_HAIKU=1` to skip the summary entirely and fall back to the directory basename.

## Troubleshooting

**Nothing happens / no emoji in tab.**
1. Did you restart Claude Code (or run `/hooks`) after install? Hook config only reloads on session start.
2. Confirm hooks are wired: `claude plugin list` should show `claude-tab-titles@claude-tab-titles ✔ enabled`.
3. Confirm the script runs in your shell: `bash ~/.claude/plugins/cache/claude-tab-titles/claude-tab-titles/*/scripts/title.sh set`. If you get errors, your terminal may not be exposing `/dev/tty` to subprocesses (rare).
4. Enable the debug log and watch:
   ```bash
   export CLAUDE_TAB_TITLES_DEBUG_LOG=/tmp/claude-tab-titles.log
   tail -f /tmp/claude-tab-titles.log
   ```
   Restart Claude Code, send a prompt. You should see `clear`, then later `set` lines.

**Emoji appears, then disappears when I click on the tab.**
That's exactly what the keeper is meant to fix. Confirm it's running: `pgrep -af "title.sh|seq 1 600"`. If you see no keeper after Stop, the `&` background detach may not be surviving on your platform — file an issue with your `bash --version` and OS.

**Title shows ❓ when Claude is just idle (not actually asking).**
The `ask`-vs-`set` filter is a string-match heuristic on the Notification message. Capture a payload via the debug log and open an issue with what the `message` looks like — happy to tighten the filter.

**Conversation pivoted, title is stale.**
Delete the cache file to force a fresh Haiku summary:
```bash
rm $TMPDIR/claude-title-<session_id>.txt
```

## Uninstall

```
/plugin uninstall claude-tab-titles@claude-tab-titles
/plugin marketplace remove claude-tab-titles
```

The script writes to `$TMPDIR/claude-title-*` and `$TMPDIR/claude-title-keeper-*.pid`. These get cleaned up on reboot, or `rm $TMPDIR/claude-title-*` immediately.

## Known rough edges

- `ask`-vs-`set` filter is a heuristic; see Troubleshooting.
- Haiku summary uses the *first* user message, cached for the session lifetime. Topic-shift detection is not implemented.
- Background keepers persist for up to 10 minutes per state event. They self-clean when the terminal closes or the next hook supersedes them. Stragglers (rare): `pkill -f title.sh`.

## Development

```bash
git clone git@github.com:gabsn/claude-tab-titles.git
cd claude-tab-titles

# Run the test suite (22 tests, ~1s, no real Haiku call).
bash tests/test.sh

# Validate manifests against the Claude Code schema.
claude plugin validate plugins/claude-tab-titles
claude plugin validate .

# Add as a local marketplace for live iteration:
claude plugin marketplace add "$(pwd)"
claude plugin install claude-tab-titles@claude-tab-titles
# After edits: claude plugin marketplace update claude-tab-titles
```

The script exposes two test seams used by `tests/test.sh`:
- `CLAUDE_TAB_TITLES_TTY=<path>` — write OSC sequences to a file instead of `/dev/tty`. Lets tests assert on the bytes that would have hit the terminal.
- `CLAUDE_TAB_TITLES_NO_KEEPER=1` — skip the 10-minute background keeper loop. Useful for tests and for users who don't need the focus-event protection.

CI runs the suite on Ubuntu and macOS via GitHub Actions on every push.

PRs welcome.

## License

MIT.
