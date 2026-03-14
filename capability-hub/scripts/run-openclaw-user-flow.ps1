<#
 * [IN]  Dependencies/Inputs:
 *  - PowerShell parameters for startup URLs, executor targets, browser-opening behavior, and `-Reconfigure`
 *  - `resolve-openclaw-workspace.ps1` plus the bootstrap helper scripts for skill installation and binding persistence
 *  - `start-openclaw-vk-stack.ps1` for the actual stack startup and MCP injection path
 *  - Local Windows tools: `node`/`npm`, optional `winget` or `choco`, and OpenClaw on Windows or WSL
 * [OUT] Outputs:
 *  - Performs first-run bootstrap for repo dependencies, managed `/plan2vk`, and persisted vibe-kanban bindings
 *  - Prompts once before attempting Windows tool installation when required
 *  - Starts or reuses the local OpenClaw + vibe-kanban + Capability Hub stack
 *  - Opens the authenticated OpenClaw Control UI and the vibe-kanban dashboard in the default browser
 *  - Prints the next user action and the stop command after bootstrap and startup succeed
 * [POS] Position in the system:
 *  - Public one-command entrypoint for first-run and repeat-run user onboarding
 *  - Delegates actual stack launch to `start-openclaw-vk-stack.ps1` and does not replace the advanced manual starter
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>
param(
  [ValidateSet("npx", "source")]
  [string]$VkMode = "npx",

  [string]$VkApiBaseUrl = "http://127.0.0.1:3001",
  [string]$GatewayUrl = "http://127.0.0.1:18789",
  [string[]]$Executors = @("CODEX", "CLAUDE_CODE"),

  [switch]$NoOpen,
  [switch]$SkipControlUi,
  [switch]$SkipVibeDashboard,
  [switch]$Reconfigure,

  [string]$StatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$capabilityHubDir = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "resolve-openclaw-workspace.ps1")

if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $capabilityHubDir "stack-processes.json"
}

function Normalize-ExecutorList([string[]]$ExecutorValues) {
  $normalized = New-Object System.Collections.Generic.List[string]

  foreach ($value in $ExecutorValues) {
    if ($null -eq $value) { continue }

    foreach ($candidate in ($value -split ",")) {
      $trimmed = $candidate.Trim()
      if ($trimmed.Length -gt 0) {
        $normalized.Add($trimmed)
      }
    }
  }

  return $normalized.ToArray()
}

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

function Resolve-OpenClawAvailability() {
  return [pscustomobject]@{
    windows_command = Get-OptionalCommand "openclaw"
    wsl_available = Test-WslCommandAvailable "openclaw"
  }
}

function Resolve-NpmCommand() {
  try {
    $npmCandidates = @(Get-Command npm -All -ErrorAction Stop)
    $npmCommand = $npmCandidates | Where-Object {
      $_.Source -and $_.Source.ToLowerInvariant().EndsWith("npm.cmd")
    } | Select-Object -First 1

    if (-not $npmCommand) {
      $npmCommand = $npmCandidates | Select-Object -First 1
    }

    if ($npmCommand -and $npmCommand.Source) {
      return $npmCommand
    }
  } catch {
    # ignore
  }

  return $null
}

function Refresh-ProcessPath() {
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = @($machinePath, $userPath) -join ";"
}

function Parse-JsonOutput([object]$Output) {
  $joined = (@($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
  if (-not [string]::IsNullOrWhiteSpace($joined)) {
    try {
      return ($joined | ConvertFrom-Json)
    } catch {
      $firstBrace = $joined.IndexOf('{')
      $lastBrace = $joined.LastIndexOf('}')
      if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
        $candidate = $joined.Substring($firstBrace, ($lastBrace - $firstBrace + 1))
        try {
          return ($candidate | ConvertFrom-Json)
        } catch {
          # fall through to last-line parsing
        }
      }
    }
  }

  $lines = @()
  foreach ($entry in @($Output)) {
    if ($null -eq $entry) { continue }
    foreach ($line in $entry.ToString().Split("`n")) {
      $trimmed = $line.Trim()
      if ($trimmed) { $lines += $trimmed }
    }
  }

  for ($index = $lines.Count - 1; $index -ge 0; $index--) {
    try {
      return ($lines[$index] | ConvertFrom-Json)
    } catch {
      continue
    }
  }

  return $null
}

function Invoke-ResolvedCommand([object]$CommandInfo, [string[]]$Arguments, [string]$WorkingDirectory = "") {
  if ($null -eq $CommandInfo -or [string]::IsNullOrWhiteSpace([string]$CommandInfo.Source)) {
    throw "Command path is missing."
  }

  Push-Location
  try {
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      Set-Location $WorkingDirectory
    }

    & $CommandInfo.Source @Arguments 2>&1 | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw ("Command failed with exit code {0}: {1}" -f $exitCode, $CommandInfo.Source)
    }
  } finally {
    Pop-Location
  }
}

function Confirm-Action([string]$PromptText) {
  $answer = Read-Host $PromptText
  if ([string]::IsNullOrWhiteSpace($answer)) { return $false }
  return @("y", "yes") -contains $answer.Trim().ToLowerInvariant()
}

function Resolve-NodeInstaller() {
  $winget = Get-OptionalCommand "winget"
  if ($winget) {
    return [pscustomobject]@{
      name = "winget"
      command = $winget
      args = @("install", "--id", "OpenJS.NodeJS.LTS", "--exact", "--accept-package-agreements", "--accept-source-agreements")
      manual = "winget install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements"
    }
  }

  $choco = Get-OptionalCommand "choco"
  if ($choco) {
    return [pscustomobject]@{
      name = "choco"
      command = $choco
      args = @("install", "nodejs-lts", "-y")
      manual = "choco install nodejs-lts -y"
    }
  }

  return $null
}

function Ensure-ExternalBootstrapTools() {
  $openclawAvailability = Resolve-OpenClawAvailability
  $nodeCommand = Get-OptionalCommand "node"
  $npmCommand = Resolve-NpmCommand
  $nodeInstaller = Resolve-NodeInstaller
  $missingItems = New-Object System.Collections.Generic.List[object]

  if (-not $nodeCommand -or -not $npmCommand) {
    if ($nodeInstaller) {
      $missingItems.Add([pscustomobject]@{
        id = "node"
        label = "Node.js LTS on Windows"
        manual = $nodeInstaller.manual
      })
    } else {
      throw "Node.js LTS is required for the one-click flow, but no supported Windows installer was found. Install Node.js LTS, reopen your shell, and rerun this command."
    }
  }

  if (-not $openclawAvailability.windows_command -and -not $openclawAvailability.wsl_available) {
    $missingItems.Add([pscustomobject]@{
      id = "openclaw"
      label = "OpenClaw CLI on Windows"
      manual = "npm install -g openclaw@latest"
    })
  }

  if ($missingItems.Count -lt 1) {
    Write-Host "Bootstrap check: required Windows tools are already available." -ForegroundColor Green
    return
  }

  Write-Host ""
  Write-Host "One-time bootstrap needs to install these Windows tools:" -ForegroundColor Yellow
  foreach ($item in $missingItems) {
    Write-Host ("- {0}" -f $item.label)
  }

  if (-not (Confirm-Action "Install the missing tools now? [y/N]")) {
    $manualSteps = @($missingItems | ForEach-Object { [string]$_.manual })
    throw ("Bootstrap stopped because required Windows tools are missing. Next action(s): {0}" -f ($manualSteps -join " ; "))
  }

  if (@($missingItems | Where-Object { $_.id -eq "node" }).Count -gt 0) {
    Write-Host "Installing Node.js LTS..." -ForegroundColor Cyan
    Invoke-ResolvedCommand -CommandInfo $nodeInstaller.command -Arguments $nodeInstaller.args
    Refresh-ProcessPath
  }

  $npmCommand = Resolve-NpmCommand
  if (@($missingItems | Where-Object { $_.id -eq "openclaw" }).Count -gt 0) {
    if (-not $npmCommand) {
      throw "Node.js installation finished, but `npm` is still not available in this shell. Reopen PowerShell and rerun the same command."
    }
    Write-Host "Installing OpenClaw on Windows..." -ForegroundColor Cyan
    Invoke-ResolvedCommand -CommandInfo $npmCommand -Arguments @("install", "-g", "openclaw@latest")
    Refresh-ProcessPath
  }

  $finalNode = Get-OptionalCommand "node"
  $finalNpm = Resolve-NpmCommand
  $finalOpenClaw = Resolve-OpenClawAvailability
  if (-not $finalNode -or -not $finalNpm) {
    throw "Bootstrap attempted to install Node.js, but `node` / `npm` is still unavailable. Reopen PowerShell and rerun the same command."
  }
  if (-not $finalOpenClaw.windows_command -and -not $finalOpenClaw.wsl_available) {
    throw "Bootstrap attempted to install OpenClaw, but no usable `openclaw` CLI is available on Windows or WSL. Reopen PowerShell and rerun the same command."
  }
}

function Ensure-CapabilityHubDependencies() {
  $nodeModulesDir = Join-Path $capabilityHubDir "node_modules"
  if (Test-Path -LiteralPath $nodeModulesDir) {
    Write-Host "Capability Hub dependencies already exist; reusing them." -ForegroundColor Green
    return
  }

  $npmCommand = Resolve-NpmCommand
  if (-not $npmCommand) {
    throw "Cannot install repo dependencies because `npm` is not available."
  }

  Write-Host "Installing Capability Hub dependencies..." -ForegroundColor Cyan
  Invoke-ResolvedCommand -CommandInfo $npmCommand -Arguments @("install", "--no-fund", "--no-audit") -WorkingDirectory $capabilityHubDir
}

function Ensure-OpenClawWorkspaceContext() {
  $context = Resolve-OpenClawWorkspaceContext
  if ($context.ok) { return $context }
  throw "OpenClaw is installed, but its workspace is not configured yet. Run `openclaw configure` once, then rerun this command."
}

function Invoke-JsonScript([string]$ScriptPath, [string[]]$Arguments) {
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $json = Parse-JsonOutput -Output $output
  return [pscustomobject]@{
    exit_code = $exitCode
    output = @($output)
    json = $json
  }
}

function Write-BufferedOutput([object[]]$Lines) {
  foreach ($line in @($Lines)) {
    if ($null -eq $line) { continue }
    Write-Host $line.ToString()
  }
}

function Open-UrlIfNeeded([string]$Url, [string]$Label, [bool]$ShouldOpen) {
  if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-Warning ("Skip opening {0}: URL missing" -f $Label)
    return
  }

  if (-not $ShouldOpen) {
    Write-Host ("- {0}: {1}" -f $Label, $Url)
    return
  }

  try {
    Start-Process $Url | Out-Null
    Write-Host ("Opened {0}: {1}" -f $Label, $Url)
  } catch {
    Write-Warning ("Failed to open {0}: {1}" -f $Label, $_.Exception.Message)
    Write-Host ("- {0}: {1}" -f $Label, $Url)
  }
}

$Executors = @(Normalize-ExecutorList $Executors)
if ($Executors.Count -eq 0) {
  throw "At least one executor must be provided. Use comma-delimited CLI input like -Executors CODEX,CLAUDE_CODE, or pass a string array from another PowerShell script."
}

$startScript = Join-Path $scriptDir "start-openclaw-vk-stack.ps1"
$ensureSkillScript = Join-Path $scriptDir "ensure-plan2vk-skill.ps1"
$ensureBindingsScript = Join-Path $scriptDir "ensure-vk-bindings.ps1"
foreach ($requiredScript in @($startScript, $ensureSkillScript, $ensureBindingsScript)) {
  if (-not (Test-Path -LiteralPath $requiredScript)) {
    throw "Required bootstrap script not found: $requiredScript"
  }
}

Write-Host "Bootstrapping the local user flow..." -ForegroundColor Cyan

$workspaceContext = Resolve-OpenClawWorkspaceContext
Ensure-ExternalBootstrapTools
if (-not $workspaceContext.ok) {
  $workspaceContext = Ensure-OpenClawWorkspaceContext
}
Ensure-CapabilityHubDependencies

Write-Host "Ensuring the managed `/plan2vk` skill is installed..." -ForegroundColor Cyan
$skillResult = Invoke-JsonScript -ScriptPath $ensureSkillScript -Arguments @(
  "-ConfigPath", $workspaceContext.config_path,
  "-GatewayUrl", $GatewayUrl,
  "-CapabilityHubDir", $capabilityHubDir
)
if ($skillResult.exit_code -ne 0 -or -not $skillResult.json -or -not [bool]$skillResult.json.ok) {
  Write-BufferedOutput -Lines $skillResult.output
  throw "Failed to install or verify the managed `/plan2vk` skill."
}
Write-Host ("- `/plan2vk` workspace ready: {0}" -f [string]$skillResult.json.workspace_path) -ForegroundColor Green
$skillState = if ([bool]$skillResult.json.skill_changed) { "installed or updated" } else { "already up to date" }
if ([bool]$skillResult.json.agents_changed) {
  $skillState = "$skillState; AGENTS fallback block synchronized"
}
Write-Host ("- Skill status: {0}" -f $skillState)

Write-Host ""
Write-Host "Running preflight and starting the local stack..." -ForegroundColor Cyan
& $startScript `
  -VkMode $VkMode `
  -VkApiBaseUrl $VkApiBaseUrl `
  -GatewayUrl $GatewayUrl `
  -Executors $Executors `
  -StatePath $StatePath | Out-Host

Write-Host ""
Write-Host "Finalizing persisted vibe-kanban bindings..." -ForegroundColor Cyan
$bindingsArgs = @(
  "-ConfigPath", $workspaceContext.config_path,
  "-VkApiBaseUrl", $VkApiBaseUrl,
  "-VkUiBaseUrl", $VkApiBaseUrl
)
if ($Reconfigure) {
  $bindingsArgs += "-Reconfigure"
}
$bindingsResult = Invoke-JsonScript -ScriptPath $ensureBindingsScript -Arguments $bindingsArgs
if ($bindingsResult.exit_code -ne 0 -or -not $bindingsResult.json -or -not [bool]$bindingsResult.json.ok) {
  Write-BufferedOutput -Lines $bindingsResult.output
  throw ("The local stack started, but persisted binding setup did not complete. Create or link a project/repository in vibe-kanban at {0}, then rerun this command{1}." -f $VkApiBaseUrl, $(if ($Reconfigure) { "" } else { " or rerun with -Reconfigure" }))
}
Write-Host ("- Using vibe-kanban binding: {0} / {1}" -f [string]$bindingsResult.json.selected_project_name, [string]$bindingsResult.json.selected_repo_name) -ForegroundColor Green
if ([bool]$bindingsResult.json.reconfigured) {
  Write-Host "- Binding choice was refreshed during this run."
} else {
  Write-Host "- Binding choice is saved for later runs."
}

if (-not (Test-Path -LiteralPath $StatePath)) {
  throw "State file not found after startup: $StatePath"
}

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$controlUiUrl = ""
if ($state.control_ui_url) {
  $controlUiUrl = [string]$state.control_ui_url
}
$vibeDashboardUrl = $VkApiBaseUrl.TrimEnd("/")

Write-Host ""
Write-Host "Opening the user workflow surfaces..." -ForegroundColor Green
if (-not $SkipControlUi) {
  Open-UrlIfNeeded -Url $controlUiUrl -Label "OpenClaw Control UI" -ShouldOpen (-not $NoOpen)
}
if (-not $SkipVibeDashboard) {
  Open-UrlIfNeeded -Url $vibeDashboardUrl -Label "vibe-kanban dashboard" -ShouldOpen (-not $NoOpen)
}

Write-Host ""
Write-Host "Next step:" -ForegroundColor Green
Write-Host "- In the OpenClaw Control UI chat, send: /plan2vk <your goal>"
Write-Host ("- Re-pick the remembered project/repository later with: powershell -ExecutionPolicy Bypass -File {0} -Reconfigure" -f $MyInvocation.MyCommand.Path)
Write-Host ("- Stop the local stack later with: powershell -ExecutionPolicy Bypass -File {0}" -f (Join-Path $scriptDir "stop-openclaw-vk-stack.ps1"))
