<#
 * [IN]  Dependencies/Inputs:
 *  - PowerShell parameters for vibe-kanban mode, URLs, executor targets, and local paths
 *  - `resolve-openclaw-config.ps1` for gateway token resolution across Windows and WSL
 *  - Local `openclaw`, `node`, `npx`, and optional WSL runtime availability
 * [OUT] Outputs:
 *  - Performs fail-fast preflight checks for the selected startup path and prints actionable install guidance when required prerequisites are missing
 *  - Starts or reuses the OpenClaw gateway, vibe-kanban API, and Capability Hub process
 *  - Injects the Capability Hub MCP server into vibe-kanban for the selected executors
 *  - Writes stack state to `stack-processes.json` and prints stack health plus the Control UI URL
 * [POS] Position in the system:
 *  - Orchestrates local stack startup and MCP wiring for OpenClaw + vibe-kanban
 *  - Does not implement MCP server behavior or vibe-kanban task execution itself, and does not continue partial startup after a failed preflight
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>
param(
  [ValidateSet("npx", "source")]
  [string]$VkMode = "npx",

  [string]$VkApiBaseUrl = "http://127.0.0.1:3001",
  [string]$VkNpxVersion = "0.1.7",

  [string]$GatewayUrl = "http://127.0.0.1:18789",
  [int]$GatewayPort = 18789,

  [switch]$SkipGateway,
  [switch]$SkipCapabilityHub,
  [switch]$SkipMcp,
  [string[]]$Executors = @("CODEX"),

  [string]$VibeSourceDir = "",
  [string]$StatePath = "",
  [string]$LogDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Dot-source the shared config resolver (Windows + WSL fallback)
. (Join-Path $scriptDir "resolve-openclaw-config.ps1")
$capabilityHubDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent $capabilityHubDir

if ([string]::IsNullOrWhiteSpace($VibeSourceDir)) {
  $VibeSourceDir = Join-Path $repoRoot "vibe-kanban-main\vibe-kanban-main"
}
if ([string]::IsNullOrWhiteSpace($LogDir)) {
  $LogDir = Join-Path $capabilityHubDir "logs"
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $capabilityHubDir "stack-processes.json"
}

$VkApiBaseUrl = $VkApiBaseUrl.TrimEnd("/")
$GatewayUrl = $GatewayUrl.TrimEnd("/")

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

$Executors = @(Normalize-ExecutorList $Executors)
if ($Executors.Count -eq 0) {
  throw "At least one executor must be provided. Use comma-delimited CLI input like -Executors CODEX,CLAUDE_CODE, or pass a string array from another PowerShell script."
}

function Ensure-Directory([string]$PathValue) {
  if (-not (Test-Path -LiteralPath $PathValue)) {
    New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
  }
}

function Test-Http([string]$Url, [int]$TimeoutSec = 2) {
  try {
    $null = Invoke-RestMethod -Method Get -Uri $Url -TimeoutSec $TimeoutSec
    return $true
  } catch {
    return $false
  }
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
  $windowsCommand = Get-OptionalCommand "openclaw"
  $wslAvailable = $false
  if (-not $windowsCommand) {
    $wslAvailable = Test-WslCommandAvailable "openclaw"
  }

  return [pscustomobject]@{
    windows_command = $windowsCommand
    wsl_available = $wslAvailable
  }
}

function Resolve-NpxCommand() {
  try {
    $npxCandidates = @(Get-Command npx -All -ErrorAction Stop)
    $npxCommand = $npxCandidates | Where-Object {
      $_.Source -and $_.Source.ToLowerInvariant().EndsWith("npx.cmd")
    } | Select-Object -First 1

    if (-not $npxCommand) {
      $npxCommand = $npxCandidates | Select-Object -First 1
    }

    if ($npxCommand -and $npxCommand.Source) {
      return $npxCommand
    }
  } catch {
    # ignore
  }

  return $null
}

function Test-CapabilityHubRunning() {
  try {
    $proc = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*openclaw-capability-hub.js*" } | Select-Object -First 1
    return ($null -ne $proc)
  } catch {
    return $false
  }
}

function New-PreflightIssue([string]$Check, [string]$Missing, [string]$Action) {
  return [pscustomobject]@{
    check = $Check
    missing = $Missing
    action = $Action
  }
}

function Test-GatewayReachable() {
  if (Test-Http "$GatewayUrl/health" 2) { return $true }
  try {
    $probe = & openclaw gateway probe 2>&1 | Out-String
    if ($probe -match "Reachable:\s*yes") { return $true }
  } catch {
    # ignore
  }
  return $false
}

function Get-GatewayToken() {
  $result = Get-OpenClawGatewayToken
  if ($result.Token) {
    $src = $result.Source
    $suffix = if ($result.Token.Length -ge 6) { $result.Token.Substring($result.Token.Length - 6) } else { "******" }
    Write-Host "Gateway token loaded from $src (***$suffix)"
  }
  return $result.Token
}

function Get-ControlUiUrl([string]$BaseUrl, [string]$GatewayToken) {
  $normalizedBaseUrl = $BaseUrl.TrimEnd("/")
  if ([string]::IsNullOrWhiteSpace($GatewayToken)) {
    return "$normalizedBaseUrl/"
  }

  return "$normalizedBaseUrl/?token=$([uri]::EscapeDataString($GatewayToken.Trim()))"
}

function Invoke-PreflightChecks() {
  $summary = New-Object System.Collections.Generic.List[string]
  $issues = New-Object System.Collections.Generic.List[object]

  $gatewayReachable = $false
  if ($SkipGateway) {
    $summary.Add("OpenClaw gateway startup is skipped by parameter.")
  } else {
    $gatewayReachable = Test-GatewayReachable
    if ($gatewayReachable) {
      $summary.Add("OpenClaw gateway is already reachable.")
    } else {
      $openclawAvailability = Resolve-OpenClawAvailability
      if ($openclawAvailability.windows_command) {
        $summary.Add("OpenClaw CLI is available on Windows.")
      } elseif ($openclawAvailability.wsl_available) {
        $summary.Add("OpenClaw CLI is not on Windows, but WSL fallback is available.")
      } else {
        $issues.Add((New-PreflightIssue `
          -Check "OpenClaw gateway startup on Windows PATH, then WSL fallback" `
          -Missing "No usable OpenClaw CLI was found for gateway startup" `
          -Action "Install OpenClaw on Windows so 'openclaw' is on PATH, or install it inside WSL and rerun. Example WSL command: npm install -g openclaw@latest"))
      }
    }
  }

  $vkHealthy = Test-VkHealth
  if ($vkHealthy) {
    $summary.Add("vibe-kanban API is already reachable.")
  } elseif ($VkMode -eq "npx") {
    $nodeCommand = Get-OptionalCommand "node"
    if ($nodeCommand) {
      $summary.Add("Node.js runtime is available for npx startup.")
    } else {
      $issues.Add((New-PreflightIssue `
        -Check "Windows PATH for 'node'" `
        -Missing "Node.js runtime required for Capability Hub and npx-based vibe-kanban startup" `
        -Action "Install Node.js 18+ on Windows, reopen your shell, and rerun the same startup command."))
    }

    $npxCommand = Resolve-NpxCommand
    if ($npxCommand) {
      $summary.Add("npx is available for vibe-kanban npx startup.")
    } else {
      $issues.Add((New-PreflightIssue `
        -Check "Windows PATH for 'npx' in '-VkMode npx'" `
        -Missing "npx required to launch vibe-kanban in npx mode" `
        -Action "Install Node.js 18+ on Windows so 'npx' is on PATH, or rerun with '-VkMode source' and a local vibe-kanban checkout."))
    }
  } else {
    $devScript = Join-Path $VibeSourceDir "scripts\dev-windows.ps1"
    if (Test-Path -LiteralPath $VibeSourceDir) {
      $summary.Add("vibe-kanban source directory exists for source mode.")
    } else {
      $issues.Add((New-PreflightIssue `
        -Check "Configured '-VibeSourceDir' for '-VkMode source'" `
        -Missing "Local vibe-kanban source checkout" `
        -Action "Clone the vibe-kanban source tree and pass '-VibeSourceDir <path>', or rerun with '-VkMode npx'."))
    }

    if (Test-Path -LiteralPath $devScript) {
      $summary.Add("vibe-kanban source startup script was found.")
    } else {
      $issues.Add((New-PreflightIssue `
        -Check "Expected source startup script at 'scripts\\dev-windows.ps1'" `
        -Missing "The source-mode dev script required by this starter" `
        -Action "Use a valid vibe-kanban source checkout, or rerun with '-VkMode npx' for the prebuilt startup path."))
    }
  }

  if ($SkipCapabilityHub) {
    $summary.Add("Capability Hub startup is skipped by parameter.")
  } elseif (Test-CapabilityHubRunning) {
    $summary.Add("Capability Hub is already running.")
  } else {
    $nodeCommand = Get-OptionalCommand "node"
    if ($nodeCommand) {
      if ($vkHealthy -or $VkMode -eq "source") {
        $summary.Add("Node.js runtime is available for Capability Hub.")
      }
    } else {
      $issues.Add((New-PreflightIssue `
        -Check "Windows PATH for 'node' before launching Capability Hub" `
        -Missing "Node.js runtime required to start Capability Hub" `
        -Action "Install Node.js 18+ on Windows, reopen your shell, and rerun the same startup command."))
    }
  }

  Write-Host ""
  Write-Host "Preflight checks:" -ForegroundColor Cyan
  foreach ($line in $summary) {
    Write-Host ("- {0}" -f $line)
  }

  if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "Preflight failed. Fix the following and rerun:" -ForegroundColor Red
    foreach ($issue in $issues) {
      Write-Host ("- Checked: {0}" -f $issue.check)
      Write-Host ("  Missing: {0}" -f $issue.missing)
      Write-Host ("  Next action: {0}" -f $issue.action)
    }
    throw "Startup preflight failed. See the required actions above."
  }

  Write-Host "- Result: all required prerequisites for this startup path are available." -ForegroundColor Green
}

function Start-GatewayIfNeeded() {
  if ($SkipGateway) { return @{ started = $false; pid = $null; location = "skipped" } }
  if (Test-GatewayReachable) {
    return @{ started = $false; pid = $null; location = "already-running" }
  }

  # Try Windows-native openclaw first
  $openclawAvailability = Resolve-OpenClawAvailability
  $openclawCmd = $openclawAvailability.windows_command

  if ($openclawCmd) {
    # Start on Windows (legacy path)
    Ensure-Directory $LogDir
    $stdout = Join-Path $LogDir "openclaw-gateway.out.log"
    $stderr = Join-Path $LogDir "openclaw-gateway.err.log"

    if ($openclawCmd.Source -and $openclawCmd.Source.ToLowerInvariant().EndsWith('.ps1')) {
      $gatewayArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $openclawCmd.Source, 'gateway', '--port', "$GatewayPort", '--verbose')
      $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $gatewayArgs -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    } else {
      $proc = Start-Process -FilePath 'openclaw' -ArgumentList @('gateway', '--port', "$GatewayPort", '--verbose') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
      if (Test-GatewayReachable) {
        return @{ started = $true; pid = $proc.Id; location = "windows" }
      }
      Start-Sleep -Seconds 1
    }

    throw "OpenClaw gateway (Windows) failed to become reachable at $GatewayUrl (see $stdout / $stderr)"
  }

  if ($openclawAvailability.wsl_available) {
    Write-Host "OpenClaw not found on Windows; starting gateway inside WSL..."
    Ensure-Directory $LogDir
    $stdout = Join-Path $LogDir "openclaw-gateway-wsl.out.log"
    $stderr = Join-Path $LogDir "openclaw-gateway-wsl.err.log"

    $proc = Start-Process -FilePath "wsl" -ArgumentList @("-e", "sh", "-c", "openclaw gateway --port $GatewayPort --verbose") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
      if (Test-GatewayReachable) {
        return @{ started = $true; pid = $proc.Id; location = "wsl" }
      }
      Start-Sleep -Seconds 1
    }

    throw "OpenClaw gateway (WSL) failed to become reachable at $GatewayUrl (see $stdout / $stderr)"
  }

  throw "OpenClaw CLI is not available on Windows or WSL. Install OpenClaw and rerun. Example WSL command: npm install -g openclaw@latest"
}

function Test-VkHealth() {
  return Test-Http "$VkApiBaseUrl/api/health" 2
}

function Start-VibeKanbanNpx([uri]$VkUri) {
  $npxCommand = Resolve-NpxCommand
  if (-not $npxCommand -or -not $npxCommand.Source) {
    throw "npx is not available on Windows PATH. Install Node.js 18+ so 'npx' is available, or rerun with '-VkMode source' and a local vibe-kanban checkout."
  }

  Ensure-Directory $LogDir
  $vkPort = if ($VkUri.Port -gt 0) { $VkUri.Port } else { 3001 }
  $env:PORT = "$vkPort"

  $stdout = Join-Path $LogDir "vibe-kanban.out.log"
  $stderr = Join-Path $LogDir "vibe-kanban.err.log"
  $npxArgs = @("-y", "vibe-kanban@$VkNpxVersion")

  $npxPath = [string]$npxCommand.Source
  $lower = $npxPath.ToLowerInvariant()

  if ($lower.EndsWith(".cmd") -or $lower.EndsWith(".bat")) {
    $quoted = '"' + $npxPath + '" ' + ($npxArgs -join ' ')
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", $quoted) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  } elseif ($lower.EndsWith(".ps1")) {
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $npxPath) + $npxArgs
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  } else {
    $proc = Start-Process -FilePath $npxPath -ArgumentList $npxArgs -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  }

  return @{ pid = $proc.Id; stdout = $stdout; stderr = $stderr }
}

function Start-VibeKanbanSource() {
  if (-not (Test-Path -LiteralPath $VibeSourceDir)) {
    throw "vibe-kanban source directory not found: $VibeSourceDir. Clone vibe-kanban locally and pass '-VibeSourceDir <path>', or rerun with '-VkMode npx'."
  }

  $devScript = Join-Path $VibeSourceDir "scripts\dev-windows.ps1"
  if (-not (Test-Path -LiteralPath $devScript)) {
    throw "vibe-kanban source startup script not found: $devScript. Use a valid source checkout, or rerun with '-VkMode npx'."
  }

  Ensure-Directory $LogDir
  $stdout = Join-Path $LogDir "vibe-kanban-source.out.log"
  $stderr = Join-Path $LogDir "vibe-kanban-source.err.log"

  $proc = Start-Process -FilePath "powershell.exe" -WorkingDirectory $VibeSourceDir -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $devScript) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  return @{ pid = $proc.Id; stdout = $stdout; stderr = $stderr }
}

function Start-VibeKanbanIfNeeded() {
  if (Test-VkHealth) {
    return @{ started = $false; pid = $null; mode = $VkMode; stdout = ""; stderr = "" }
  }

  $vkUri = [uri]$VkApiBaseUrl
  if ($VkMode -eq "source") {
    $start = Start-VibeKanbanSource
  } else {
    $start = Start-VibeKanbanNpx $vkUri
  }

  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    if (Test-VkHealth) {
      return @{ started = $true; pid = $start.pid; mode = $VkMode; stdout = $start.stdout; stderr = $start.stderr }
    }
    Start-Sleep -Seconds 1
  }

  $hint = if ($VkMode -eq "source") {
    "Source mode requires CMake + libclang + Rust toolchain; try VkMode=npx for prebuilt startup."
  } else {
    "npx startup did not expose /api/health in time; check logs."
  }
  throw "vibe-kanban failed to become reachable at $VkApiBaseUrl. $hint (logs: $($start.stdout), $($start.stderr))"
}

function Find-HubProcess() {
  try {
    return Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*openclaw-capability-hub.js*" } | Select-Object -First 1
  } catch {
    return $null
  }
}

function Start-CapabilityHubIfNeeded([string]$GatewayToken) {
  if ($SkipCapabilityHub) {
    return @{ started = $false; pid = $null; stdout = ""; stderr = "" }
  }

  $existing = Find-HubProcess
  if ($existing) {
    return @{ started = $false; pid = $existing.ProcessId; stdout = ""; stderr = "" }
  }

  $hubScript = Join-Path $capabilityHubDir "src\openclaw-capability-hub.js"
  if (-not (Test-Path -LiteralPath $hubScript)) {
    throw "Hub script not found: $hubScript"
  }
  if (-not (Get-OptionalCommand "node")) {
    throw "Node.js runtime not found on Windows PATH. Install Node.js 18+ and rerun so Capability Hub can start."
  }

  Ensure-Directory $LogDir
  $stdout = Join-Path $LogDir "capability-hub.out.log"
  $stderr = Join-Path $LogDir "capability-hub.err.log"

  $env:OPENCLAW_GATEWAY_URL = $GatewayUrl
  if (-not [string]::IsNullOrWhiteSpace($GatewayToken)) {
    $env:OPENCLAW_GATEWAY_TOKEN = $GatewayToken
  }

  $proc = Start-Process -FilePath "node" -WorkingDirectory $capabilityHubDir -ArgumentList @($hubScript) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  return @{ started = $true; pid = $proc.Id; stdout = $stdout; stderr = $stderr }
}

function Inject-McpConfig() {
  if ($SkipMcp) { return }
  $injectScript = Join-Path $scriptDir "vk-inject-mcp.ps1"
  if (-not (Test-Path -LiteralPath $injectScript)) {
    Write-Warning "Skip MCP injection: script not found: $injectScript"
    return
  }

  if (-not (Test-VkHealth)) {
    Write-Warning "Skip MCP injection: vibe-kanban API not reachable"
    return
  }

  & $injectScript -VkApiBaseUrl $VkApiBaseUrl -Executors $Executors -Mode merge -GatewayUrl $GatewayUrl | Out-Host
}

Ensure-Directory $LogDir

Invoke-PreflightChecks
$gateway = Start-GatewayIfNeeded
$token = Get-GatewayToken
$vk = Start-VibeKanbanIfNeeded
$hub = Start-CapabilityHubIfNeeded $token
Inject-McpConfig
$controlUiUrl = Get-ControlUiUrl -BaseUrl $GatewayUrl -GatewayToken $token

$state = [ordered]@{
  timestamp = (Get-Date).ToString("o")
  vk_mode = $VkMode
  gateway_url = $GatewayUrl
  control_ui_url = $controlUiUrl
  vk_api_base_url = $VkApiBaseUrl
  pids = [ordered]@{
    gateway = $gateway.pid
    gateway_location = $gateway.location
    vibe_kanban = $vk.pid
    capability_hub = $hub.pid
  }
  logs = [ordered]@{
    vibe_kanban_stdout = $vk.stdout
    vibe_kanban_stderr = $vk.stderr
    capability_hub_stdout = $hub.stdout
    capability_hub_stderr = $hub.stderr
  }
}

($state | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $StatePath -Encoding UTF8

Write-Host ""
Write-Host "Stack ready:" -ForegroundColor Green
Write-Host ("- Gateway: {0} ({1}, {2})" -f $GatewayUrl, $(if (Test-GatewayReachable) { "reachable" } else { "unreachable" }), $gateway.location)
Write-Host ("- Control UI: {0}" -f $controlUiUrl)
Write-Host ("- vibe-kanban API: {0} ({1})" -f $VkApiBaseUrl, $(if (Test-VkHealth) { "healthy" } else { "unhealthy" }))
Write-Host ("- Capability Hub: {0}" -f $(if ($hub.pid) { "pid=$($hub.pid)" } else { "already running or disabled" }))
Write-Host ("- MCP inject executors: {0}" -f ($Executors -join ", "))
Write-Host ("- State file: {0}" -f $StatePath)
