# Claude Stack: plan and checklist

> **What we will do:** Build a small floating box that shows every Claude tab and its status.
> **What we get at the end:** An always-on-top, draggable stack. It blinks when a tab needs you. It starts by itself with `claude`.
> **What I must keep ready:** Click "Allow" once when macOS asks "ClaudeStack wants to control Ghostty".

## 1. The problem, in different situations

| # | Situation | What goes wrong today | What the stack does |
|---|---|---|---|
| 1 | Claude asks a question (AskUserQuestion) in a hidden tab | Work stops and nobody knows | Orange row blinks, sound, Mac banner |
| 2 | Claude asks for permission to run a tool | Same | Same, label "Permission" |
| 3 | Claude asks to approve a plan (ExitPlanMode) | Same | Same, label "Plan approval" |
| 4 | A subagent asks for permission | Same | Same (subagent prompts also need you) |
| 5 | Claude finished the task | You do not notice for a long time | Green "Done" row with time since |
| 6 | Done for more than 10 minutes | Forgotten tab | Grey "Idle" row |
| 7 | New tab, no prompt yet | - | "Ready" row |
| 8 | You pressed Esc. No "done" event comes | Row would say "Running" forever | After 10 minutes with no event: yellow "Maybe stuck" |
| 9 | You closed the tab or killed Claude. No "end" event comes | Dead row stays | App checks the Claude process. If it is gone, the row is removed |
| 10 | Two tabs in the same repo | You cannot tell them apart | Row shows the git branch and your last prompt |
| 11 | You work in another app, or full screen, or another desktop | Box would cover your work | Box shows on every desktop. Drag it away. Double-click to shrink it to a pill |
| 12 | You type in another app | A floating box could steal the keyboard | The box never takes keyboard focus |
| 13 | No Claude tab is open | Empty box adds clutter | Box hides itself |
| 14 | The app was quit or crashed | No status | The next Claude event starts it again |
| 15 | Many tool calls run in parallel | Two hooks write one file at the same time | Small file lock, and the write is atomic (temp file + rename) |
| 16 | Claude outside Ghostty (VS Code, Terminal) | - | Row still shows. A click brings that app to the front |
| 17 | The tab moved its chat to the background (`/bg`, agent view). The tab process stays alive | Old row showed Idle forever | Chat file ends with `continued-in`, so the row is removed |
| 18 | `/clear` or `/resume` in the same tab | Two rows for one tab | One Claude process keeps only its newest row |
| 19 | Claude makes a "spare" background session in advance | Fake "Ready" row | Background row with no prompt yet is hidden |
| 20 | Background chat (no tab) | Looked like a tab | Row shows a "BG" label. It stays while the chat runs |
| 21 | Tab closed in Ghostty | - | Row goes after about 5 s. Ghostty keeps a closed tab alive 5 s for Cmd+Z (`undo-timeout`) |

## 2. How it is built

```
claude (each tab)
  └─ hooks ──> ~/.claude/stack/stack-hook.sh ──> ~/.claude/stack/sessions/<id>.json
                                                         │
ClaudeStack.app (one, floating) <── reads every 0.5 s ───┘
  └─ click a row ──> osascript ──> Ghostty focuses that tab
```

### Hook events and the status they set

| Event | Status |
|---|---|
| SessionStart | Ready (and start the app if it is not running) |
| UserPromptSubmit | Running (save the prompt, first 80 characters) |
| PreToolUse, tool is AskUserQuestion | Needs you: "Question" |
| PreToolUse, tool is ExitPlanMode | Needs you: "Plan approval" |
| PermissionRequest | Needs you: "Permission" |
| Notification: permission_prompt / elicitation_dialog | Needs you |
| Notification: idle_prompt | No change |
| PreToolUse / PostToolUse / PostToolUseFailure, other tools | Running. Clears "Needs you" only if it comes from the same agent that asked |
| Stop | Done |
| SessionEnd | Row removed |

Hook rules: print nothing, always exit 0, finish in a few milliseconds.

### Status look

| Status | Colour | Icon | Motion |
|---|---|---|---|
| Needs you | Orange `#FF9A00` | raised hand | Fast blink, glowing border, sound "Glass", Mac banner |
| Running | Blue `#427BBF` | hourglass | Slow pulse |
| Maybe stuck | Yellow `#F4A500` | warning | Steady |
| Done | Green `#06C27A` | check | Steady |
| Ready | Muted green | circle | Steady |
| Idle | Grey `#8A9BAE` | moon | Steady |

Rows are sorted: Needs you, then Running, then Stuck, then Done, then Ready, then Idle.

### Box behaviour
- Floating panel, on all desktops and over full-screen apps.
- Drag anywhere. The position is saved.
- Double-click the title to switch between the full stack and a small pill.
- Right-click opens a menu: sound on/off, banner on/off, sound when done, compact, reset position, quit.
- Click a row to jump to that Ghostty tab.

## 3. Files

| File | What |
|---|---|
| `~/.claude/stack/stack-hook.sh` | The hook script (bash + jq) |
| `~/.claude/stack/ClaudeStack.swift` | The app source |
| `~/.claude/stack/build.sh` | Builds `~/Applications/ClaudeStack.app` |
| `~/.claude/stack/sessions/` | One status file per tab |
| `~/.claude/settings.json` | Hooks added. Backup at `settings.json.bak-claude-stack` |

## 4. Checklist

### Build
- [x] Write `stack-hook.sh`
- [x] Write `ClaudeStack.swift` and `build.sh`
- [x] Build the app and sign it (ad hoc)
- [x] Back up `settings.json`
- [x] Add the hooks and keep every existing hook (ctx-optimize, voice, SOD, speak)
- [x] Check that `settings.json` is still valid JSON

### Test
- [x] Hook with fake input: the right file and status for every event
- [x] Hook prints nothing and exits 0, even with broken input
- [x] Hook speed is under 100 ms
- [x] Parallel hooks do not corrupt the file
- [x] App shows rows, colours, and sort order (screenshot)
- [x] Blink on "Needs you" (two screenshots differ). Sound and banner: Sundaran to confirm by ear
- [x] Dead process makes the row disappear
- [x] Box hides when there are no sessions
- [ ] Click focuses the right Ghostty tab (Sundaran: click a row, then Allow the macOS prompt)
- [x] Real check: a new Claude tab shows up by itself

### Hand over
- [x] Short "how to use" note for Sundaran
- [x] How to turn it off

## 5. How to use

- It starts by itself when you run `claude`. Nothing to enable.
- **Drag** the box anywhere. **Double-click** the title for the small pill.
- **Click a row** to jump to that tab. The first time, macOS asks "Claude Stack wants to control Ghostty". Click Allow.
- **Right-click** for: sound, banner, sound when done, compact, reset position, quit.
- Mac banners show as "Script Editor". To allow them: System Settings, Notifications, Script Editor.

## 6. Change or turn off

| Want | Do |
|---|---|
| Rebuild after editing the Swift file | `~/.claude/stack/build.sh`, then `pkill -x ClaudeStack` |
| Stop it for now | Right-click, Quit (it comes back with the next Claude event) |
| Remove it fully | `cp ~/.claude/settings.json.bak-claude-stack ~/.claude/settings.json` (only if you made no other settings change since), or delete the 9 `stack-hook.sh` entries, then `pkill -x ClaudeStack` |
| Change "stuck" or "idle" time | `stuckAfter` and `idleAfter` in `ClaudeStack.swift`, then rebuild |
| Test picture without the screen | `~/Applications/ClaudeStack.app/Contents/MacOS/ClaudeStack --snapshot out.png` |
