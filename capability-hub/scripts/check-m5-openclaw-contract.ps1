<#
[IN] Dependencies/Inputs:
 - OpenClaw config from Windows and/or WSL (`resolve-openclaw-config.ps1`).
 - Optional runtime hint (`-Runtime auto|windows|wsl`), marker text, and skill name.
 - OpenClaw status output (auto mode) for runtime platform detection.
 - `openclaw skills list` CLI output for runtime skill registry visibility.
[OUT] Outputs:
 - JSON runtime readiness result (stdout and optional file output).
 - Exit code 0 when the M5 workspace skill is present/listed and the AGENTS fallback note is synchronized; non-zero otherwise.
[POS] Position in the system:
 - M5.4 guardrail that validates the actual runtime OpenClaw chat-path readiness.
 - Prevents false positives caused by checking only `%USERPROFILE%` or only legacy AGENTS prefix text.
#>
param(
  [string]$ConfigPath = "",
  [ValidateSet("auto", "windows", "wsl")]
  [string]$Runtime = "auto",
  [string]$Marker = "M5 Dispatch Contract",
  [string]$SkillName = "plan2vk",
  [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "resolve-openclaw-config.ps1")

function Get-OptionalCommand([string]$Name) {
  try {
    $commands = @(Get-Command $Name -All -ErrorAction Stop)
    if ($commands.Count -gt 0) {
      return $commands[0]
    }
  } catch {
    # ignore
  }
  return $null
}

function Test-WslCommandAvailable([string]$Name) {
  $output = $null
  try {
    $output = wsl -e sh -c "command -v $Name 2>/dev/null" 2>$null | Out-String
  } catch {
    # ignore
  }
  return (-not [string]::IsNullOrWhiteSpace(([string]$output).Trim()))
}

function Invoke-OpenClawCli([string[]]$Arguments, [ValidateSet("windows", "wsl")] [string]$Mode) {
  if ($Mode -eq "wsl") {
    $output = wsl -e openclaw @Arguments 2>&1 | Out-String
    return [pscustomobject]@{
      exit_code = $LASTEXITCODE
      output = [string]$output
    }
  }

  $output = & openclaw @Arguments 2>&1 | Out-String
  return [pscustomobject]@{
    exit_code = $LASTEXITCODE
    output = [string]$output
  }
}

function Get-DefaultWslDistro {
  try {
    $raw = wsl -l -q 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return "" }
    foreach ($line in @($raw)) {
      $clean = ($line -replace "`0", "").Trim()
      if ($clean) { return $clean }
    }
  } catch {}
  return ""
}

function Convert-LinuxPathToUnc([string]$LinuxPath, [string]$Distro) {
  if ([string]::IsNullOrWhiteSpace($LinuxPath) -or [string]::IsNullOrWhiteSpace($Distro)) { return "" }
  if (-not $LinuxPath.StartsWith('/')) { return "" }
  $relative = $LinuxPath.TrimStart('/').Replace('/', '\\')
  foreach ($prefix in @('\\wsl.localhost', '\\wsl$')) {
    $candidate = Join-Path $prefix "$Distro\\$relative"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return ""
}

function Parse-OpenClawConfig([string]$ResolvedPath) {
  if (-not (Test-Path -LiteralPath $ResolvedPath)) {
    throw "OpenClaw config not found: $ResolvedPath"
  }
  return Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
}

function Resolve-ConfigForRuntime([string]$RuntimeMode, [string]$ManualPath) {
  if (-not [string]::IsNullOrWhiteSpace($ManualPath)) {
    return [ordered]@{
      path = $ManualPath
      source = "manual"
      runtime_platform = ""
      windows_path = ""
      wsl_path = ""
    }
  }

  $windowsPath = Join-Path $env:USERPROFILE ".openclaw\openclaw.json"
  $windowsExists = Test-Path -LiteralPath $windowsPath

  $forceMissing = Join-Path $env:TEMP "__force_missing_openclaw__.json"
  $wslResolved = Resolve-OpenClawConfig -WindowsPath $forceMissing
  $wslPath = if ($wslResolved -and $wslResolved.Path) { [string]$wslResolved.Path } else { "" }

  $runtimePlatform = ""
  if ($RuntimeMode -eq "auto") {
    try {
      $statusJson = openclaw status --json | ConvertFrom-Json
      if ($statusJson.gateway -and $statusJson.gateway.self -and $statusJson.gateway.self.platform) {
        $runtimePlatform = [string]$statusJson.gateway.self.platform
      }
    } catch {
      $runtimePlatform = ""
    }
  }

  if ($RuntimeMode -eq "windows") {
    if (-not $windowsExists) { throw "Windows OpenClaw config not found: $windowsPath" }
    return [ordered]@{
      path = $windowsPath
      source = "windows"
      runtime_platform = $runtimePlatform
      windows_path = $windowsPath
      wsl_path = $wslPath
    }
  }

  if ($RuntimeMode -eq "wsl") {
    if ([string]::IsNullOrWhiteSpace($wslPath)) { throw "WSL OpenClaw config not found." }
    return [ordered]@{
      path = $wslPath
      source = [string]$wslResolved.Source
      runtime_platform = $runtimePlatform
      windows_path = if ($windowsExists) { $windowsPath } else { "" }
      wsl_path = $wslPath
    }
  }

  # auto: if runtime appears Linux and WSL config exists, prefer WSL.
  if ($runtimePlatform.ToLower().Contains("linux") -and -not [string]::IsNullOrWhiteSpace($wslPath)) {
    return [ordered]@{
      path = $wslPath
      source = [string]$wslResolved.Source
      runtime_platform = $runtimePlatform
      windows_path = if ($windowsExists) { $windowsPath } else { "" }
      wsl_path = $wslPath
    }
  }

  $resolved = Resolve-OpenClawConfig
  if (-not $resolved.Path) {
    throw "Unable to resolve OpenClaw config path (windows/wsl)."
  }
  return [ordered]@{
    path = [string]$resolved.Path
    source = [string]$resolved.Source
    runtime_platform = $runtimePlatform
    windows_path = if ($windowsExists) { $windowsPath } else { "" }
    wsl_path = $wslPath
  }
}

function Resolve-OpenClawCommandMode([object]$ResolvedInfo, [string]$RuntimeMode) {
  $windowsCommand = Get-OptionalCommand "openclaw"
  $wslAvailable = Test-WslCommandAvailable "openclaw"

  if ($RuntimeMode -eq "windows") {
    if (-not $windowsCommand) { throw "Windows OpenClaw CLI is not available." }
    return "windows"
  }

  if ($RuntimeMode -eq "wsl") {
    if (-not $wslAvailable) { throw "WSL OpenClaw CLI is not available." }
    return "wsl"
  }

  $platform = [string]$ResolvedInfo.runtime_platform
  if ($platform.ToLower().Contains("linux") -and $wslAvailable) { return "wsl" }
  if (([string]$ResolvedInfo.source).StartsWith("wsl") -and $wslAvailable) { return "wsl" }
  if ($windowsCommand) { return "windows" }
  if ($wslAvailable) { return "wsl" }

  throw "No usable OpenClaw CLI was found on Windows or WSL."
}

$resolvedInfo = Resolve-ConfigForRuntime -RuntimeMode $Runtime -ManualPath $ConfigPath
$openclawCommandMode = Resolve-OpenClawCommandMode -ResolvedInfo $resolvedInfo -RuntimeMode $Runtime
$cfg = Parse-OpenClawConfig -ResolvedPath $resolvedInfo.path

$workspaceRaw = ""
if ($cfg.agents -and $cfg.agents.defaults -and $cfg.agents.defaults.workspace) {
  $workspaceRaw = [string]$cfg.agents.defaults.workspace
}
if ([string]::IsNullOrWhiteSpace($workspaceRaw)) {
  throw "agents.defaults.workspace is missing in OpenClaw config."
}

$workspaceResolved = $workspaceRaw
$wslDistro = Get-DefaultWslDistro
if ($workspaceRaw.StartsWith('/')) {
  $uncWorkspace = Convert-LinuxPathToUnc -LinuxPath $workspaceRaw -Distro $wslDistro
  if (-not [string]::IsNullOrWhiteSpace($uncWorkspace)) {
    $workspaceResolved = $uncWorkspace
  }
}

$agentsPath = Join-Path $workspaceResolved "AGENTS.md"
$agentsExists = Test-Path -LiteralPath $agentsPath
$raw = if ($agentsExists) { Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8 } else { "" }

$skillsDir = Join-Path $workspaceResolved "skills"
$skillsReadmePath = Join-Path $skillsDir "README.md"
$skillsReadmeExists = Test-Path -LiteralPath $skillsReadmePath
$skillPath = Join-Path $skillsDir (Join-Path $SkillName "SKILL.md")
$skillExists = Test-Path -LiteralPath $skillPath
$skillRaw = if ($skillExists) { Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8 } else { "" }

$markerFound = $raw -match [regex]::Escape($Marker)
$prefixFound = $raw -match "/plan2vk"
$toolFound = $raw -match "cap\.vk_plan_and_dispatch|m5-dispatch-client\.js"
$fallbackNoteFound = ($raw -match "workspace skill command") -and ($raw -match "fallback note")
$skillDispatchFound = $skillRaw -match "cap\.vk_plan_and_dispatch"
$skillExecFallbackFound = ($skillRaw -match "\bwrite\b") -and ($skillRaw -match "\bexec\b") -and ($skillRaw -match "m5-dispatch-client\.js")
$skillsListOutput = ""
$skillsListCommandOk = $false
$skillListed = $false
try {
  $skillsListResult = Invoke-OpenClawCli -Arguments @("skills", "list") -Mode $openclawCommandMode
  $skillsListOutput = $skillsListResult.output
  $skillsListCommandOk = ($skillsListResult.exit_code -eq 0)
  if ($skillsListCommandOk) {
    $skillListed = $skillsListOutput -match ("(?im)\b" + [regex]::Escape($SkillName) + "\b")
  }
} catch {
  $skillsListOutput = $_.Exception.Message
}
$missing = @()
if (-not $agentsExists) { $missing += "agents_file_missing" }
if ($agentsExists -and -not $markerFound) { $missing += "marker_missing" }
if ($agentsExists -and -not $prefixFound) { $missing += "prefix_missing" }
if ($agentsExists -and -not $toolFound) { $missing += "dispatch_path_missing" }
if ($agentsExists -and -not $fallbackNoteFound) { $missing += "fallback_note_missing" }
if (-not $skillsReadmeExists) { $missing += "skills_readme_missing" }
if (-not $skillExists) { $missing += "skill_file_missing" }
if ($skillExists -and -not $skillDispatchFound) { $missing += "skill_dispatch_missing" }
if ($skillExists -and -not $skillExecFallbackFound) { $missing += "skill_exec_fallback_missing" }
if (-not $skillsListCommandOk) { $missing += "skills_registry_unavailable" }
if ($skillsListCommandOk -and -not $skillListed) { $missing += "skill_not_listed" }

$ok = $agentsExists -and $markerFound -and $prefixFound -and $toolFound -and $fallbackNoteFound -and $skillsReadmeExists -and $skillExists -and $skillDispatchFound -and $skillExecFallbackFound -and $skillsListCommandOk -and $skillListed
$result = [ordered]@{
  ok = $ok
  runtime_mode = $Runtime
  runtime_platform = [string]$resolvedInfo.runtime_platform
  config_path = [string]$resolvedInfo.path
  config_source = [string]$resolvedInfo.source
  openclaw_command_mode = $openclawCommandMode
  windows_config_path = [string]$resolvedInfo.windows_path
  wsl_config_path = [string]$resolvedInfo.wsl_path
  workspace_raw = $workspaceRaw
  workspace_path = $workspaceResolved
  agents_path = $agentsPath
  skills_dir = $skillsDir
  skills_readme_path = $skillsReadmePath
  skills_readme_exists = $skillsReadmeExists
  skill_name = $SkillName
  skill_path = $skillPath
  skill_exists = $skillExists
  skill_dispatch_found = $skillDispatchFound
  skill_exec_fallback_found = $skillExecFallbackFound
  skills_list_command_ok = $skillsListCommandOk
  skill_listed = $skillListed
  marker = $Marker
  marker_found = $markerFound
  prefix_found = $prefixFound
  tool_found = $toolFound
  fallback_note_found = $fallbackNoteFound
  contract_mode = if ($fallbackNoteFound) { "fallback_note" } else { "legacy_primary_or_missing" }
  skills_list_excerpt = if ($skillsListOutput) { ($skillsListOutput -split "`r?`n" | Select-Object -First 8) } else { @() }
  missing_items = $missing
}

$json = $result | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $dir = Split-Path -Parent $OutputPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $json | Out-File -FilePath $OutputPath -Encoding UTF8
}

Write-Output $json
if ($ok) { exit 0 }
exit 1
