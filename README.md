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

## The reader

Click the expand button in the header (or the chat icon on a row) and the box grows into a
reader: your sessions on the left, the selected chat on the right.

- **Read:** headings, bold, real tables, coloured code. Each code block has a **Copy** button,
  each answer has one too, and **Copy last** copies Claude's last answer. **A- / A+** changes
  the text size. Tool calls are folded into "N steps"; click to see the command and its output.
- **Resize:** drag the left, right or bottom edge, or a bottom corner. Size and place are saved.
- **Send:** type in the box and press Enter (Shift+Enter for a new line). The text is pasted
  into the real Claude in that Ghostty tab, so every Claude Code feature works. "Sending to"
  names the target tab, and the app checks that tab before it sends.
- **Slash commands:** type `/` for a list of built-in commands, your skills and plugin skills.
  Commands that open a menu (`/model`, `/config`, ...) bring the tab to the front.
- **Voice:** hold space in the box. The Mac's speech engine writes your words into the box, so
  you can fix them before sending. A short tap is a normal space. macOS asks for Microphone and
  Speech Recognition permission the first time.
- **Answer from the box:** when a tab needs you, the reader shows the question options, or
  Allow once / Deny for a permission, or Approve / Keep planning for a plan. Anything more
  complex has an **Open tab** button.
- **Agents:** when Claude runs subagents, an Agents bar shows each one: type, description,
  current step, step count and time. Running agents come first, finished ones fold away. Click
  an agent to read its own chat; "Back to main chat" returns. The small stack shows a
  "N agents" badge while agents work. (Workflow agents are not shown yet.)
- **Stop:** sends Esc to the tab while Claude is working.
- **Keyboard:** the box takes the keyboard only after you click inside the reader. Press Esc to
  give it back.

Limits: answers appear one message at a time, not word by word, because Claude Code saves whole
messages. Sending works for Ghostty tabs only; other terminals and background chats are
read-only.

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
- `Transcript.swift` reads the chat file (`transcript_path`) for the reader, only the new bytes
  each time. `Reader.swift` feeds it to `web/reader.html`, a local page that uses the bundled
  `marked` and `highlight.js` (in `web/vendor/`, with their licences). Raw HTML in an answer is
  shown as text, never run.
- `Ghostty.swift` pastes text and presses keys in a tab through Ghostty's AppleScript
  (`input text`, `send key`). `Voice.swift` is the hold-space speech input.
- `PLAN.md` lists every situation the app handles, and why. `READER-PLAN.md` does the same for
  the reader.
- `tests/run.sh` checks the chat parser against `tests/fixture.jsonl` (made-up content).

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
