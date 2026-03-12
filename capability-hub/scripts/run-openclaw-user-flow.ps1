<#
 * [IN]  Dependencies/Inputs:
 *  - PowerShell parameters for vibe-kanban mode, URLs, executor targets, and browser-opening behavior
 *  - `start-openclaw-vk-stack.ps1` for the actual stack startup and MCP injection path
 *  - `stack-processes.json` emitted by the stack starter for Control UI URL discovery
 * [OUT] Outputs:
 *  - Starts or reuses the local OpenClaw + vibe-kanban + Capability Hub stack
 *  - Opens the authenticated OpenClaw Control UI and the vibe-kanban dashboard in the default browser
 *  - Prints the next user action and the stop command after startup
 * [POS] Position in the system:
 *  - Provides a thin one-click operator entrypoint for the documented local user flow
 *  - Does not replace the underlying stack starter or manage process lifecycle independently
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

  [string]$StatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$capabilityHubDir = Split-Path -Parent $scriptDir

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
if (-not (Test-Path -LiteralPath $startScript)) {
  throw "Stack starter not found: $startScript"
}

Write-Host "Starting the local user flow..." -ForegroundColor Cyan
& $startScript `
  -VkMode $VkMode `
  -VkApiBaseUrl $VkApiBaseUrl `
  -GatewayUrl $GatewayUrl `
  -Executors $Executors `
  -StatePath $StatePath | Out-Host

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
Write-Host ("- Stop the local stack later with: powershell -ExecutionPolicy Bypass -File {0}" -f (Join-Path $scriptDir "stop-openclaw-vk-stack.ps1"))
