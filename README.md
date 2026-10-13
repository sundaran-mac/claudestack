# Claude Stack

A small floating box for macOS that shows every Claude Code session and its live status.
When you run many Claude tabs at once, it tells you which tab needs you, which one is done,
and which one is still working. Nothing waits silently in a hidden tab.

On Windows (Claude Code in WSL), see [Windows](#windows) at the end.

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

Click the expand button in the header (or the chat icon on a row) to open the reader window:
your sessions on the left, the selected chat on the right.

- **Read:** headings, bold, real tables, coloured code. Each code block has a **Copy** button,
  each answer has one too, and **Copy last** copies Claude's last answer. **A- / A+** changes
  the text size. Tool calls are folded into "N steps"; click to see the command and its output.
- **A normal Mac window:** the reader has the real red, yellow and green buttons. Green is true
  full screen in its own space. While the reader is open the app shows in the Dock and Cmd+Tab,
  and the small stack hides while the reader is in front. Closing the reader keeps the small
  stack running. The Dock icon is drawn by `tools/make-icon.swift`.
- **Keep on top:** the pin at the top right of the title bar (or Window, Keep on Top,
  Cmd+Shift+T) makes the reader float above every app on every desktop, like the small stack.
  Click it again for a normal window. The choice is remembered.
- **Read:** headings, bold, real tables, coloured code. Each code block has a **Copy** button,
  each answer has one too, and **Copy last** copies Claude's last answer. **A- / A+** changes
  the text size. Tool calls are folded into "N steps"; click to see the command and its output.
- **Window buttons** (top left, as on every Mac window): red closes the reader and keeps the
  small stack, yellow shrinks to the small stack, green fills the screen and a second click
  brings back the old size and place. Double-clicking the title bar does the same as green.
- **Resize:** like any window. Size and place are saved.
- **Send:** type in the box and press Enter (Shift+Enter for a new line). The text is pasted
  into the real Claude in that Ghostty tab, so every Claude Code feature works. "Sending to"
  names the target tab, and the app checks that tab before it sends.
- **Slash commands:** type `/` for a list of built-in commands, your skills and plugin skills.
  Commands that open a menu (`/model`, `/config`, ...) bring the tab to the front.
- **Voice:** hold space in the box. It is Claude Code's own voice mode, the same as in Ghostty:
  the app sends a "held space" to that tab with Ghostty's `text` action, Claude Code listens and
  writes your words (with its punctuation), then the app moves them into the box so you can edit
  before sending. A short tap is a normal space. Ghostty tabs only, and off while a tab needs you.
  To read the words, the app borrows the clipboard for a moment and puts your content back.
- **Answer from the box:** when a tab needs you, the reader shows the question options, or
  Allow once / Deny for a permission, or Approve / Keep planning for a plan. Anything more
  complex has an **Open tab** button.
- **Agents tab:** a summary (running, done, steps, how many ran at the same time), a live map of
  who started whom (the lead on top, agents below, flowing lines to running ones; a vertical tree
  when they do not fit in one row), and a timeline with one bar per agent. Click any agent to read
  its chat. Generated HTML uses `data-style`, because the page's security rule ignores `style=`.
- **Agents:** when Claude runs subagents, an Agents bar shows each one: type, description,
  current step, step count and time. Running agents come first, finished ones fold away. Click
  an agent to read its own chat; "Back to main chat" returns. The small stack shows a
  "N agents" badge while agents work. (Workflow agents are not shown yet.)
- **Stop:** sends Esc to the tab while Claude is working.

Limits: answers appear one message at a time, not word by word, because Claude Code saves whole
messages. Sending works for Ghostty tabs only; other terminals and background chats are
read-only.

## The day coach

Long days with Claude are easy to stretch too far. The coach watches your work time and nudges you.

- **Day strip** (small stack and reader): work time, time left, and two rings that fill up to the
  next water and rest reminder. Blue in the day, amber from the time-check hour, green at the end.
- **Reminders**, one at a time, in calm colours (orange blinking stays for "Claude needs you"):
  water every 60 minutes of work, rest after 120 minutes without a break, lunch, "30 minutes
  left", "Day complete" with today's numbers, and a gentle note every 15 minutes if you keep
  working after the day ends. Each has **Done** and **10 min later**. After you answer one, the
  next water or rest waits at least 15 minutes.
- **Work time** counts while you use the Mac: any keyboard or mouse input in the last 5 minutes
  (macOS reports this without any permission). Ten minutes with no input count as a break and
  start the rest timer again. A shorter pause, like reading an answer, does not.
- **End-of-day time check:** `day-hook.sh` (a `UserPromptSubmit` hook) adds a note to new prompts
  after the time-check hour on workdays. Claude then answers first with a `timecheck` block, which
  the reader shows as a card with a clock ring: fits, or does not fit, what to do now and what to
  leave for tomorrow. If it does not fit, Claude asks before starting.
- **Automatic start (on by default):** the day starts at your first keyboard or mouse use after
  5 AM (or an earlier Claude prompt in today's log, if the app opened late). It ends after your
  **work hours** (8 by default), plus the part of lunch after your start. The time check starts
  30 minutes before that end. When the hours are done, the strip turns green with a tick and the
  "Day complete" card shows. The app writes today's hours to `days/<date>.hours.json` for the
  hook. Settings shows today's start and end, greyed out, and **Start my day again from now** for
  a day that started too early. Turn it off to use fixed start and end times instead.
- **Settings** tab in the reader: automatic start and work hours, or fixed day start and end and
  time-check hour, lunch, workdays, water and rest minutes, sounds, Day off. Saved to
  `~/.claude/stack/day.json`, which the hook also reads.
- No reminders on weekends or when "Day off" is on.

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
- `DayCoach.swift` and `DayViews.swift` are the day coach. `stack-hook.sh` writes one line per
  prompt, finished task and agent to `~/.claude/stack/days/<date>.jsonl` (gitignored).
- `tests/run.sh` checks the chat parser against `tests/fixture.jsonl` (made-up content), the
  agents, scrolling, a simulated workday for the coach, and the time-check hook.

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
chmod +x ~/.claude/stack/stack-hook.sh ~/.claude/stack/day-hook.sh ~/.claude/stack/build.sh
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

**3b. Add the day coach's time check (optional).** One more `UserPromptSubmit` hook. Unlike
`stack-hook.sh`, this one does print: after the time-check hour on workdays, its note reaches
Claude with your prompt.

```sh
jq '.hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":"$HOME/.claude/stack/day-hook.sh","timeout":5}]}]' \
  ~/.claude/settings.json > /tmp/claude-settings.json && mv /tmp/claude-settings.json ~/.claude/settings.json
```

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

## Windows

The same app for Windows 11, with Claude Code running in WSL (Ubuntu). It has every feature above.
Two things work differently, and `WINDOWS-PLAN.md` explains why:

- **Start Claude with `cs` instead of `claude`.** `cs` runs Claude inside tmux, on its own tmux
  server, so the app can type into it (Send, Stop, answers, voice). Every argument is passed on:
  `cs --resume` works. Plain `claude` tabs still show rows, status, the reader and agents, but you
  cannot send to them from the box.
- **Windows Terminal instead of Ghostty.** Clicking a row selects that exact tab: tmux puts a tag
  such as `[cs-1234]` in the tab title, and the app finds it.

### Requirements

- Windows 11 with WSL (Ubuntu), and Windows Terminal
- In WSL: `sudo apt install tmux jq` and Node 18 or newer
- On Windows: Node.js from nodejs.org (it builds the app; Electron is downloaded once)
- Claude Code installed in WSL

### Install

Run inside WSL. The README's Mac steps 1 to 3 become one script:

```sh
git clone https://github.com/sundaran-mac/claudestack.git ~/.claude/stack
~/.claude/stack/win/install.sh             # add --day-hook for the evening time check (step 3b)
```

It builds `%LOCALAPPDATA%\ClaudeStack\build\dist\ClaudeStack-win32-x64\ClaudeStack.exe`, adds the
hook to the nine events (once: running it again never adds a second copy, and a backup is kept at
`settings.json.bak-claude-stack`), links `cs` into `~/.local/bin`, and starts the app. After that,
the app starts by itself on the next Claude event, like on the Mac. Run it again after you change
the code.

Open a new Windows Terminal tab and run `cs`.

### Differences from the Mac

| Mac | Windows |
|---|---|
| Mac banner (as "Script Editor") | Windows notification. Click it to jump to that tab |
| Sounds Glass, Pop, Tink | Windows sounds from `C:\Windows\Media` |
| Cmd+C, Cmd+V, Cmd+Enter | Ctrl+C, Ctrl+V, Ctrl+Enter |
| Cmd+Shift+T: keep on top | Ctrl+Shift+T, or the pin above the session list |
| Settings in UserDefaults | `%APPDATA%\ClaudeStack\prefs.json`; the coach's daily numbers in `~/.claude/stack/days/<date>.coach.json` |
| Voice: Claude Code's voice mode in Ghostty | The same, through tmux. It needs Claude Code voice to work in WSL (a microphone in WSL) |
| `day-hook.sh` says "Sundaran" | It reads `"name"` from `~/.claude/stack/day.json` ("The user" if not set) |

### Tests

```sh
tests/run.sh               # the Mac suite; on Linux it uses win/bin/claudestack and the built app
win/tests/hook-test.sh     # the hook in a temporary HOME
node win/tests/tmux-test.js  # Send, keys, input line and the tty check against a fake Claude in tmux
win/bin/app-test --snapshot out.png   # also --coach-snapshot, --reader-snapshot transcript.jsonl out.png
```

### Remove it

```sh
~/.claude/stack/win/install.sh --remove
```

### Troubleshooting

| Problem | Check |
|---|---|
| The box never shows | Is `stack-hook.sh` in `~/.claude/settings.json`? Do files appear in `~/.claude/stack/sessions/`? Is `~/.claude/stack/app-path` there? |
| Send is greyed: "started with plain claude" | Start Claude with `cs` |
| `cs: command not found` | Add `~/.local/bin` to your PATH in `~/.zshrc` or `~/.bashrc` |
| A click brings Windows Terminal forward but not the tab | Windows Terminal may hide app titles: Settings, your profile, Advanced, turn off "Suppress title changes" |
| The app shows nothing at all | `%APPDATA%\ClaudeStack\backend.log` has the WSL side's errors |
