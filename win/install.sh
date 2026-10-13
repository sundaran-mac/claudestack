#!/bin/bash
# Claude Stack for Windows. Run inside WSL: win/install.sh [--day-hook] | --remove
#   Builds %LOCALAPPDATA%\ClaudeStack\...\ClaudeStack.exe (Electron, with the Windows Node and npm),
#   adds the hooks to ~/.claude/settings.json (once; running it again does not add them twice),
#   puts the `cs` command in ~/.local/bin, and starts the app.
#   --day-hook also adds the day coach's evening time check (day-hook.sh), as step 3b of the README.
#   --remove undoes all of it.
set -euo pipefail
repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
data="$HOME/.claude/stack"
settings="$HOME/.claude/settings.json"
say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ -n "${WSL_DISTRO_NAME:-}" ] || die "run this inside WSL (Ubuntu), not in Windows or on a Mac."
win() { (cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c "$@" 2>/dev/null | tr -d '\r'); }
localappdata="$(win echo %LOCALAPPDATA%)"
[ -n "$localappdata" ] && [ "$localappdata" != "%LOCALAPPDATA%" ] || die "could not reach Windows (cmd.exe). Is WSL interop on?"
appwin="$localappdata\\ClaudeStack"
applin="$(wslpath -u "$appwin")"
exe_win="$appwin\\build\\dist\\ClaudeStack-win32-x64\\ClaudeStack.exe"

stop_app() { /mnt/c/Windows/System32/taskkill.exe /IM ClaudeStack.exe /F >/dev/null 2>&1 || true; }

if [ "${1:-}" = "--remove" ]; then
  say "Removing Claude Stack"
  stop_app
  if [ -f "$settings" ]; then
    jq '.hooks |= ((. // {}) | map_values(map(select(tostring | test("stack-hook|day-hook") | not))) | with_entries(select(.value | length > 0)))' \
      "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
  fi
  rm -f "$HOME/.local/bin/cs" "$data/app-path" "$data/app.alive"
  rm -rf "$applin"
  rm -f "$(wslpath -u "$(win echo %APPDATA%)")/Microsoft/Windows/Start Menu/Programs/Claude Stack.lnk"
  say "Done. Your chats are untouched. Session files stay in $data (delete it if you like)."
  exit 0
fi

# ---------- Check what is needed ----------
for c in jq tmux node; do command -v "$c" >/dev/null || die "$c is missing in WSL. Install it: sudo apt install $c"; done
node_major=$(node -p 'process.versions.node.split(".")[0]')
[ "$node_major" -ge 18 ] || die "Node 18 or newer is needed in WSL (found $(node -v))."
win where npm >/dev/null || die "Node.js for Windows is missing (npm not found). Install it from nodejs.org, then run this again."

# ---------- Build the Windows app ----------
say "1/4 Building the Windows app in $appwin"
stop_app
build="$applin/build"
mkdir -p "$build"
# Copy the app and the reader page; keep node_modules between builds.
find "$build" -mindepth 1 -maxdepth 1 ! -name node_modules ! -name dist ! -name package-lock.json -exec rm -rf {} +
cp -r "$repo/win/app/." "$build/"
cp -r "$repo/web" "$build/web"
node "$repo/win/tools/icns-to-ico.js" "$repo/AppIcon.icns" "$build/icon.ico" "$build/icon.png" >/dev/null
node -e '
  const [distro, nodeBin, backend, out] = process.argv.slice(1);
  require("fs").writeFileSync(out, JSON.stringify({ distro, node: nodeBin, backend }, null, 2));
' "$WSL_DISTRO_NAME" "$(readlink -f "$(command -v node)")" "$repo/win/backend/main.js" "$build/config.json"
# Windows starts in the folder WSL is in, so no Windows path (with its spaces) goes through cmd's quoting.
printf '@echo off\r\nnpm install --no-audit --no-fund --loglevel=error && npm run pack --silent\r\n' > "$build/build.cmd"
(cd "$build" && /mnt/c/Windows/System32/cmd.exe /c build.cmd) || die "the Windows build failed (see the npm output above)."
[ -f "$(wslpath -u "$exe_win")" ] || die "the build did not make $exe_win"
mkdir -p "$data/sessions"
printf '%s' "$exe_win" > "$data/app-path"

# ---------- Hooks ----------
say "2/4 Adding the hooks to $settings"
chmod +x "$repo/stack-hook.sh" "$repo/day-hook.sh" "$repo/win/cs" "$repo/win/bin/claudestack" "$repo/win/bin/app-test" 2>/dev/null || true
mkdir -p "$HOME/.claude"
[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak-claude-stack"
# The path is quoted, because the hook command runs through a shell.
jq --arg cmd "'$repo/stack-hook.sh'" '
  .hooks //= {} |
  reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure",
          "PermissionRequest","Notification","Stop","SessionEnd") as $e (.;
    if ((.hooks[$e] // []) | tostring | test("stack-hook")) then .
    else .hooks[$e] = ((.hooks[$e] // []) + [{"hooks":[{"type":"command","command":$cmd,"timeout":5}]}]) end)
' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
if [ "${1:-}" = "--day-hook" ]; then
  jq --arg cmd "'$repo/day-hook.sh'" '
    if ((.hooks.UserPromptSubmit // []) | tostring | test("day-hook")) then .
    else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$cmd,"timeout":5}]}] end
  ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
fi
jq -e . "$settings" >/dev/null || { cp "$settings.bak-claude-stack" "$settings"; die "settings.json broke; the backup was put back."; }

# ---------- cs ----------
say "3/4 Adding the cs command"
mkdir -p "$HOME/.local/bin"
ln -sf "$repo/win/cs" "$HOME/.local/bin/cs"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "   Add ~/.local/bin to your PATH, for example: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

# ---------- Start ----------
say "4/4 Starting Claude Stack"
(cd /mnt/c && setsid /mnt/c/Windows/System32/cmd.exe /c start "" "$exe_win" &) </dev/null >/dev/null 2>&1
say "Done. Open a new Windows Terminal tab and run: cs"
