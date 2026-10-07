# Claude Stack Reader: plan (reviewed, waiting for Sundaran's approval)

Decided 2026-10-07: same box expands; web view with marked + highlight.js bundled; voice by holding space in the box, using the Mac's speech engine (changed after the test below); all 3 phases in one round.

> **What we will do:** Turn Claude Stack into a big, resizable reader and a prompt box for every Claude tab.
> **What we get at the end:** Read Claude's answers like ChatGPT, copy with one click, and send prompts, slash commands and voice to any tab.
> **What I must keep ready:** Answers to the 4 questions in chat. Later, click "Allow" if macOS asks again about Ghostty.

## 1. The key fact that makes this possible

Ghostty 1.3.1 (installed) has two AppleScript commands:

| Command | What it does |
|---|---|
| `input text "..." to terminal <id>` | Pastes text into that exact tab, even if the tab is hidden |
| `send key "enter" to terminal <id>` | Presses a key in that tab (Enter, Esc, 1, 2, arrows) |

So the box does **not** run its own Claude. It types into the **real** Claude in your tab.
Result: every Claude Code ability works from the box: slash commands, skills, plan mode, tools, Docker, everything.
The tab stays the single source of truth.

## 2. What you will see

```
+------------------------------------------------------------------+
| [stack] Claude            2 need you               [-] [compact] |
+--------------------+---------------------------------------------+
| > humini-live-app  |  humini-live-app  .  main        A- A+ [copy]|
|   main . Running   |---------------------------------------------|
|   claudestack      |  YOU   Give me your suggestions...          |
|   Needs you  (!)   |                                             |
|   arus-proof       |  CLAUDE                                     |
|   Done 4m          |   ## My suggestion          <- big, bold    |
|                    |   | Option | What you get |  <- real table  |
|                    |   ```bash              [Copy]               |
|                    |   npm run test                              |
|                    |   ```                                       |
|                    |   > Ran: git status   (click to open)       |
|                    |---------------------------------------------|
|                    | [Question] Which one? [A] [B] [C]           |
|                    | Sending to: humini-live-app . main          |
|                    | [ Type or /command...        ] [mic] [Send] |
+--------------------+---------------------------------------------+
                                                   drag any edge ^
```

Two modes, one window:
- **Small mode:** today's stack, unchanged.
- **Reader mode:** list on the left, chat on the right. Drag any edge or corner to resize. Size and place are saved.

## 3. Phases

| Phase | What | Done when |
|---|---|---|
| **1. Reader** | Expand button, resize both ways, chat view from the transcript, headings, bold, tables, code colours, Copy on each code block, Copy whole answer, A-/A+ text size, tool calls folded | You read a real long answer and copy a code block in one click |
| **2. Prompt box** | Send text to the tab, multi-line (Shift+Enter), `/` opens a list of slash commands and skills, Stop button (sends Esc), hold space for voice (Mac speech engine, text lands in the box) | You send `/context` from the box and the answer shows in the reader |
| **3. Answer from the box** | When a tab needs you: question options as buttons, permission Allow / Deny buttons, plan Approve | You answer an AskUserQuestion without opening the tab |

## 4. How it is built

| Part | How |
|---|---|
| Read the chat | The hook already saves `transcript_path`. The app reads that `.jsonl` file. Only new bytes are read each time (files can be many MB) |
| Show the chat | A web view (`WKWebView`) inside the app with a small HTML page. Markdown and code-colour libraries are **saved inside the app**, no internet |
| Copy | Copy buttons call back into Swift, which writes to the Mac clipboard |
| Send | `input text` + `send key "enter"` to the tab's Ghostty terminal id (the app already finds this id today) |
| Slash list | Built-in commands + `~/.claude/skills`, `~/.claude/commands`, plugin skills, and the repo's `.claude/` |
| Voice | Hold space in the box (over 0.3 s). Apple's Speech engine (`SFSpeechRecognizer`, English India) turns speech into text **in the box**. A short tap is a normal space. macOS asks for Microphone and Speech permission once |
| Files | Split `ClaudeStack.swift` into a few files. `build.sh` compiles all of them and copies the web files into the app |

## 5. Plan review (I attacked my own plan; what I found and the fix)

| # | Risk | Fix in the plan |
|---|---|---|
| 1 | **Prompt goes to the wrong tab.** Worst bug possible | "Sending to: <project> . <branch>" shown above the box. Before sending, check the terminal id still exists and its tty matches. If not sure: do not send, show an error |
| 2 | Today the box never takes the keyboard (so it never steals your typing) | Keep that. It takes the keyboard **only** when you click inside the prompt box. Press Esc or click elsewhere and it gives it back |
| 3 | Claude is busy when you send | Claude Code queues it, same as typing in the tab. Box shows "Queued" |
| 4 | Multi-line prompt pressed Enter too early | `input text` pastes as one block (bracketed paste), then one Enter |
| 5 | Tab is VS Code, Terminal, or a BG session | Reader works. Prompt box is greyed with the reason |
| 6 | Transcript is huge (10+ MB) | Show the last 50 messages, "Load earlier" button, read only new bytes |
| 7 | Answer still being written | Transcript updates per message, not per word. Reader shows "Claude is working..." with the current tool name. Not word-by-word like ChatGPT. Honest limit |
| 8 | Subagent and system lines clutter the chat | Hide sidechain lines, meta lines and thinking. Tool calls folded to one line |
| 9 | Repo is public on GitHub | No chat text is ever committed. `sessions/` stays ignored. Web libraries are open-source files only |
| 10 | Phase 3 sends keys to a menu | Menus can change between Claude Code versions. Phase 3 shows the buttons **and** a "Open tab" fallback. Tested on the current version |
| 12 | Tested 2026-10-07: Ghostty `send key` sends no text for space or letters, so Claude Code's own voice mode cannot be started from outside. Sundaran chose option A: the Mac's speech engine in the box |
| 11 | Window too big covers work | Collapse button returns to small mode in one click. Double-click title still works |

## 6. Tests

- Snapshot mode (`--snapshot`) extended to draw reader mode from a test transcript file.
- A test transcript in `tests/` with: table, code block, long answer, tool call, question.
- Swift check that the transcript parser skips sidechain and meta lines.
- By hand (you): resize both ways, copy a code block, send a prompt, send `/context`, Stop, mic, answer a question.

## 7. Not in scope

- Word-by-word streaming (Claude Code does not write it to disk).
- Running Claude without a tab.
- Windows or Linux.

## 8. Added after the first approval (2026-10-07)

| Ask | What was built | Checked by |
|---|---|---|
| Show subagents | Agents bar (type, description, current step, steps, time), agent chat view, "N agents" badge on the row, status chip on each Agent step | 11 agent tests on made-up files, the real curvv session (4 agents, 0.06 s), one live agent run from Claude |
| Copy box for messages to people | A ```` ```message ```` block becomes a "Ready to send" card. Copy puts rich text (bold, lists) and plain text on the clipboard. Copy buttons on tables and quote boxes. Rule added to Sundaran's global CLAUDE.md | Picture test |
| Scroll jumped back while reading | Following stops on any scroll up and starts again only at the very bottom. "Jump to latest" button. Agents bar updates only its timers | `--scroll-test`: 0 px moved while reading, follows at the bottom |

Bugs found during live tests and fixed: Ghostty key names are `arrowUp` / `arrowDown`; new Claude Code saves slash commands as `system` / `local_command` lines; a notice that arrives while Claude is busy is saved as `queue-operation` plus a `queued_command` attachment; the "always allow" option's wording changes per prompt, so that button was dropped.
