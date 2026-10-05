# Claude Stack

A small floating box for macOS that shows every Claude Code session and its live status.
When you run many Claude tabs at once, it tells you which tab needs you, which one is done,
and which one is still working. Nothing waits silently in a hidden tab.

## What it shows

| Status | Colour | Meaning |
|---|---|---|
| Needs you | Orange, blinking, sound, banner | Claude asked a question, wants a permission, or wants a plan approved |
| Running | Blue, slow pulse | Claude is working |
| Maybe stuck | Yellow | Running, but no event for 10 minutes |
| Done | Green | Claude finished. "Stopped" if you pressed Esc |
| Ready | Muted green | New session, no prompt yet |
| Idle | Grey moon | Done for more than 10 minutes |

Each row shows the project folder, the git branch, and your last prompt. A **BG** label marks a
background session (one that runs under the Claude daemon, not in a tab, for example after `/bg`).

Rows go away by themselves:

- when Claude exits or the tab is closed (Ghostty keeps a closed tab alive for 5 seconds so
  Cmd+Z can bring it back, so the row goes after about 5 seconds);
- when a chat moves to a new session id (`/bg`, agent view, `/clear`, `/resume`);
- spare background sessions that Claude starts in advance are never shown.

## How it works

```
claude (each tab)
  └─ hooks ──> stack-hook.sh ──> ~/.claude/stack/sessions/<session-id>.json
                                              │
ClaudeStack.app (one floating box) <── reads every 0.5 s
  └─ click a row ──> osascript ──> Ghostty focuses that tab
```

- `stack-hook.sh` runs on Claude Code hook events. It writes one small JSON file per session.
  It prints nothing and always exits 0, so it can never break Claude.
- `ClaudeStack.swift` is the app. It reads those files, checks the Claude process is still alive,
  and draws the box.
- `PLAN.md` lists every situation the app handles, and why.

## Requirements

- macOS 14 or later, Apple Silicon (the build targets `arm64`)
- Xcode Command Line Tools, for `swiftc`: `xcode-select --install`
- `jq`: ships with macOS 15 and later at `/usr/bin/jq`, or `brew install jq`
- Claude Code
- Ghostty, for click-to-focus. Other terminals still show rows; a click brings that app to the front

## Install

**1. Get the code into `~/.claude/stack`.** The hook and the app expect this exact folder.

```sh
git clone https://github.com/sundaran-mac/claudestack.git ~/.claude/stack
chmod +x ~/.claude/stack/stack-hook.sh ~/.claude/stack/build.sh
```

**2. Build the app.** This makes `~/Applications/ClaudeStack.app`.

```sh
~/.claude/stack/build.sh
```

**3. Add the hooks to Claude Code.** This backs up your settings first, then adds the hook to
nine events and keeps every hook you already have.

```sh
cp ~/.claude/settings.json ~/.claude/settings.json.bak-claude-stack 2>/dev/null || echo '{}' > ~/.claude/settings.json
jq '
  .hooks //= {} |
  reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure",
          "PermissionRequest","Notification","Stop","SessionEnd") as $e (.;
    .hooks[$e] = ((.hooks[$e] // []) + [{"hooks":[{"type":"command","command":"$HOME/.claude/stack/stack-hook.sh","timeout":5}]}]))
' ~/.claude/settings.json > /tmp/claude-settings.json && mv /tmp/claude-settings.json ~/.claude/settings.json
```

Run it once only. Running it twice adds the hook twice.

**4. Start Claude.** Open a new tab and run `claude`. The box starts by itself on the first event.

**5. Allow Ghostty control.** The first time you click a row, macOS asks
"Claude Stack wants to control Ghostty". Click Allow.

**6. Banners (optional).** Mac banners show as "Script Editor". To allow them:
System Settings, Notifications, Script Editor.

## Use

- **Drag** the box anywhere. The position is saved.
- **Double-click** the title to switch between the full box and a small pill.
- **Click a row** to jump to that tab.
- **Right-click** for: sound on/off, banner on/off, sound when done, compact, reset position, quit.
- The box hides itself when no Claude session is open.

## Change it

| Want | Do |
|---|---|
| Rebuild after editing the Swift file | `~/.claude/stack/build.sh && pkill -x ClaudeStack` (it restarts on the next Claude event) |
| Change the "stuck" or "idle" time | Edit `stuckAfter` and `idleAfter` in `ClaudeStack.swift`, then rebuild |
| Picture of the box without the screen | `~/Applications/ClaudeStack.app/Contents/MacOS/ClaudeStack --snapshot out.png` |
| Stop it for now | Right-click, Quit. It comes back with the next Claude event |

## Remove it

```sh
pkill -x ClaudeStack
jq '.hooks |= (map_values(map(select(tostring | test("stack-hook") | not))) | with_entries(select(.value | length > 0)))' \
  ~/.claude/settings.json > /tmp/claude-settings.json && mv /tmp/claude-settings.json ~/.claude/settings.json
rm -rf ~/Applications/ClaudeStack.app ~/.claude/stack
```

## Troubleshooting

| Problem | Check |
|---|---|
| The box never shows | Is the hook in `~/.claude/settings.json`? Do files appear in `~/.claude/stack/sessions/` when you run `claude`? |
| The box is not on this screen | It may be on another display. Right-click, Reset position, or run `defaults delete local.sundaran.claudestack topLeft` and restart it |
| A row stays after its tab closed | Wait 5 seconds (Ghostty undo). If it still stays, check `ps -p <pid>` from that session file; the row goes when that process exits |
| Clicking a row does nothing | System Settings, Privacy and Security, Automation: allow Claude Stack to control Ghostty |

## Privacy

Everything stays on your Mac. Session files hold your last prompt (first 80 characters), so the
`sessions/` folder is in `.gitignore` and is never committed.
