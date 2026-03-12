param(
  [string]$StatePath = "",
  [switch]$StopGateway
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$capabilityHubDir = Split-Path -Parent $scriptDir

if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $capabilityHubDir "stack-processes.json"
}

function Stop-IfAlive([Nullable[int]]$TargetPid, [string]$Name) {
  if (-not $TargetPid) { return }
  try {
    $proc = Get-Process -Id $TargetPid -ErrorAction Stop
    Stop-Process -Id $TargetPid -Force -ErrorAction Stop
    Write-Host ("Stopped {0} pid={1}" -f $Name, $TargetPid)
  } catch {
    Write-Host ("Skip {0} pid={1} (not running)" -f $Name, $TargetPid)
  }
}

if (-not (Test-Path -LiteralPath $StatePath)) {
  Write-Host "State file not found: $StatePath"
  Write-Host "Trying best-effort cleanup for capability hub process..."
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*openclaw-capability-hub.js*" } | ForEach-Object {
    try {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
      Write-Host ("Stopped capability hub pid={0}" -f $_.ProcessId)
    } catch {
      # ignore
    }
  }
  return
}

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json

$vkPid = $null
$hubPid = $null
$gatewayPid = $null

if ($state.pids) {
  if ($state.pids.vibe_kanban) { $vkPid = [int]$state.pids.vibe_kanban }
  if ($state.pids.capability_hub) { $hubPid = [int]$state.pids.capability_hub }
  if ($state.pids.gateway) { $gatewayPid = [int]$state.pids.gateway }
}

Stop-IfAlive -TargetPid $vkPid -Name "vibe-kanban"
Stop-IfAlive -TargetPid $hubPid -Name "capability-hub"

if ($StopGateway) {
  if ($gatewayPid) {
    Stop-IfAlive -TargetPid $gatewayPid -Name "openclaw-gateway"
  } else {
    try {
      & openclaw gateway stop | Out-Host
    } catch {
      Write-Warning "Failed to stop gateway via CLI: $($_.Exception.Message)"
    }
  }
} else {
  Write-Host "Gateway left running (pass -StopGateway to stop it)."
}

Write-Host "Stop script done."
