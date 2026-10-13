# Claude Stack on Windows: plan

Decided 2026-10-08 with Anu: same features as the Mac app. Claude runs in WSL inside tmux (the `cs`
command), and the app is an Electron app on Windows.

> **What we will do:** Port Claude Stack to Windows 11 with Claude Code running in WSL.
> **What we get at the end:** The floating stack, the reader, Send, Stop, answers, voice, agents and the day coach, on Windows.
> **What I must keep ready:** Start Claude with `cs` instead of `claude` when you want the box to type into that tab.

## 1. The key facts

| Fact | What it means |
|---|---|
| Ghostty's AppleScript (`input text`, `send key`) does not exist on Windows. Windows Terminal has no way to type into a tab from outside, and Linux blocks typing into another terminal (`TIOCSTI` is off) | The app cannot type into a plain `claude` tab |
| tmux can type into any of its panes (`send-keys`, `paste-buffer`) and read the screen (`capture-pane`) | `cs` runs Claude inside tmux, on its own tmux server (`-L claudestack`), so the app can type into it exactly |
| The hook runs inside the pane, so it sees `$TMUX_PANE` | The session file names its pane. No title trick is needed to find the target |
| Windows Terminal tabs can be found through UI Automation by their title | tmux puts a tag (`[cs-<id>]`) in the tab title, so a click selects that exact tab |
| Electron reports system idle time (`powerMonitor.getSystemIdleTime`) | The day coach measures you, as on the Mac |

## 2. How it is built

```
Windows Terminal tab
  └─ cs ──> tmux (-L claudestack) ──> claude ──> hooks ──> stack-hook.sh ──> ~/.claude/stack/sessions/<id>.json   (WSL)
                                                                                         │
ClaudeStack.exe (Electron, Windows) ── wsl.exe ──> backend (node, WSL) <── reads every 0.5 s
  ├─ small stack window (always on top, never takes the keyboard)
  ├─ reader window: sidebar page + web/reader.html
  └─ click / send / keys / voice ──> backend ──> tmux send-keys / paste-buffer / capture-pane
                                └─> winhelper.ps1 (UI Automation) selects the Windows Terminal tab
```

| Mac part | Windows part |
|---|---|
| `ClaudeStack.swift` (Store, Row, alerts) | `win/backend/store.js` (WSL), alerts in `win/app/main.js` |
| `Transcript.swift`, `Agents.swift` | `win/backend/transcript.js`, `win/backend/agents.js`, same logic line for line |
| `Ghostty.swift` | `win/backend/tmux.js`. Every send checks that the pane's tty is the session's tty |
| `TabVoice.swift` | `win/backend/voice.js`: held space is `send-keys " "` every 10 ms; the input line is read with `capture-pane`, no clipboard borrowing |
| `Reader.swift` (ReaderModel) | `win/backend/reader.js` (state, items, agents) plus the page bridge in `win/app/main.js` |
| `DayCoach.swift` | `win/backend/coach.js`. Per-day numbers go to `days/<date>.coach.json` instead of UserDefaults |
| `App.swift`, `Views.swift`, `DayViews.swift` | `win/app/` Electron main process and two pages: `stack.html` and `shell.html` (sidebar and settings) |
| NSSound, banners | Windows sounds in `C:\Windows\Media`, Windows toast notifications |
| `build.sh` | `win/install.sh`: builds `%LOCALAPPDATA%\ClaudeStack\ClaudeStack.exe` and adds the hooks |
| `--parse`, `--agents`, `--coach-sim` | `win/bin/claudestack` (same flags), so `tests/run.sh` runs unchanged on WSL |

The backend runs in WSL so every file read, process check and tmux call is native Linux. The
Windows side only draws, plays sounds, shows toasts, reads idle time and selects terminal tabs.

## 3. Shared files: changes

| File | Change | Mac impact |
|---|---|---|
| `stack-hook.sh` | Saves `tmux_pane`, `tmux_socket`, `wt_session`, and the outer terminal. Linux branches for: start the app (`open` and `pgrep -q` are Mac only), lock age (`find -mtime +5s` is BSD only), no-tty value (`?` on Linux, `??` on Mac) | None. Mac branches unchanged |
| `day-hook.sh` | The name comes from `day.json` (`name`), so Claude does not call Anu "Sundaran" | Set `"name": "Sundaran"` in `day.json` to keep the old wording |
| `web/reader.js` | Posts to Electron as well as WebKit. Ctrl shortcuts on Windows, Cmd on Mac. "Ghostty" wording made neutral | None |
| `tests/run.sh` | Picks `win/bin/claudestack` on Linux | None |

## 4. Situations (in addition to the Mac list in `PLAN.md`)

| # | Situation | What the app does |
|---|---|---|
| W1 | Claude started with plain `claude`, not `cs` | Row, status, reader and agents all work. Send is greyed: "Start Claude with cs to send from here" |
| W2 | Tab closed | tmux ends the session, Claude exits, the row goes on the next 0.5 s check |
| W3 | The pane was reused or its tty changed | Send refuses: "Could not prove this is the right tab. Nothing was sent." |
| W4 | Windows Terminal hides app titles (`suppressApplicationTitle`) | The tab cannot be found by title, so the click only brings Windows Terminal to the front |
| W5 | Claude in VS Code's terminal | Row shows; click brings VS Code to the front |
| W6 | The app is not running when Claude starts | The hook sees no heartbeat (`~/.claude/stack/app.alive` older than 5 s) and starts `ClaudeStack.exe` in the background |
| W7 | The backend (WSL side) crashes | The app restarts it after 2 s |
| W8 | Claude Code voice does not work in WSL (no microphone in WSL) | Voice reports "No words came through". Everything else works. This is a Claude Code and WSL limit, not the app's |
| W9 | WSL runs on UTC while Windows has the real time zone | The app passes the Windows zone to the backend, which writes it to `~/.claude/stack/tz` (a POSIX offset when WSL lacks the zone name, such as Asia/Calcutta). Both hooks use it, so day hours, the day log date and the evening time check follow the Windows clock |

## 5. Tests

- `tests/run.sh` on WSL: the parser, agents, scroll, coach sim and time-check hook tests from the Mac.
- `win/tests/hook-test.sh`: the hook with fake input in a temp `HOME`: tmux pane saved, lock works, prints nothing, exits 0.
- `win/tests/tmux-test.sh`: a fake "claude" in a tmux pane: send, keys, input line read and clear, tty check refuses a wrong pane.
- `ClaudeStack.exe --snapshot out.png` and `--reader-snapshot` for pictures.
- By hand (Anu): start `cs`, see the row, click it, send `/context`, answer a question, Stop.

## 6. Not in scope

- Claude Code running natively on Windows (not in WSL). The hooks are bash, and Windows has no tmux.
- Typing into plain `claude` tabs (see W1).

## 7. Checklist (2026-10-08)

### Build
- [x] Backend in WSL: store, transcript, agents, reader model, tmux, voice, coach, slash commands
- [x] Electron app: small stack, reader window (sidebar + `web/reader.html`), Settings, alerts, test modes
- [x] `winhelper.ps1`: selects the Windows Terminal tab by its tag
- [x] `cs` and `win/tmux.conf`; `win/install.sh` (also `--day-hook`, `--remove`)
- [x] Hook and day hook changes; reader page bridge; README

### Test
- [x] `tests/run.sh`: 41 of 41, including the scroll test in the Windows app
- [x] `win/tests/hook-test.sh`: 15 of 15 (tmux pane saved, stale lock, parallel hooks, silent, exit 0)
- [x] `win/tests/tmux-test.js`: 11 of 11 (send, keys, input line, refusals for a wrong tty, a dead Claude, no pane)
- [x] Pictures: small stack, pill, every reminder card, reader
- [x] Live: this machine's session shows up by itself; plain `claude` is read-only with the reason shown
- [x] Live: a real Claude in `cs`: row with pane and tab tag, `/context` sent from the backend, its output in the reader, a message for another session refused
- [x] Live: a click jumps to the right Windows Terminal tab and back (UI Automation)
- [x] Live: the reader window with two sessions
- [ ] Voice: the app side works (stream, read back, clear message). Claude Code did not start listening in this WSL, so no words came back. Needs Claude Code voice working in WSL
- [ ] By hand (Anu): click a row, send from the reader, answer a question, Stop, a Windows notification
