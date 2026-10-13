# Claude Stack helper: brings a Claude tab to the front. Windows port of the Focuser in ClaudeStack.swift.
# Started once by the app and kept running (PowerShell takes a second to start). It reads one JSON
# request per line on stdin: {"op":"focus","tag":"[cs-1234]","term":"WindowsTerminal"} and answers one line.
# The tag is in the tab title (tmux sets it, see win/tmux.conf), so UI Automation finds the exact tab.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CsWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);

  // Windows lets only the app in front give the focus away. Joining the input of the window in
  // front lifts that rule for this call; the Alt tap is the fallback that also lifts it.
  public static bool Front(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9);
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return true;
    uint me = GetCurrentThreadId();
    uint them = GetWindowThreadProcessId(fg, IntPtr.Zero);
    bool joined = them != 0 && them != me && AttachThreadInput(me, them, true);
    BringWindowToTop(h);
    bool ok = SetForegroundWindow(h);
    if (joined) AttachThreadInput(me, them, false);
    if (!ok) {
      keybd_event(0x12, 0, 0, UIntPtr.Zero);
      keybd_event(0x12, 0, 2, UIntPtr.Zero);
      ok = SetForegroundWindow(h);
    }
    return ok;
  }
}
"@

$AE = [Windows.Automation.AutomationElement]
$Scope = [Windows.Automation.TreeScope]

function TerminalWindows {
  $c = New-Object Windows.Automation.PropertyCondition($AE::ClassNameProperty, "CASCADIA_HOSTING_WINDOW_CLASS")
  return $AE::RootElement.FindAll($Scope::Children, $c)
}

function FocusTag($tag) {
  if (-not $tag) { return $false }
  $tabCond = New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
  foreach ($w in (TerminalWindows)) {
    foreach ($t in $w.FindAll($Scope::Descendants, $tabCond)) {
      if ($t.Current.Name.Contains($tag)) {
        [void][CsWin]::Front([IntPtr]$w.Current.NativeWindowHandle)
        $p = $null
        if ($t.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select() }
        return $true
      }
    }
  }
  return $false
}

function FocusApp($term) {
  # Not a cs tab, or the tab title is hidden: bring the terminal app to the front.
  $names = switch -Regex ($term) { "vscode" { @("Code") } default { @("WindowsTerminal") } }
  foreach ($n in $names) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { return [CsWin]::Front($p.MainWindowHandle) }
  }
  return $false
}

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  try {
    $req = $line | ConvertFrom-Json
    if ($req.op -eq "focus") {
      if (FocusTag $req.tag) { "tab $($req.tag)" }
      elseif (FocusApp $req.term) { "app $($req.term)" }
      else { "none" }
    }
  } catch {
    "error $($_.Exception.Message)"
  }
  [Console]::Out.Flush()
}
