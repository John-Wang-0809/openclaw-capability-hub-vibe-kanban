<#
 * [IN]  Dependencies/Inputs:
 *  - PowerShell parameters for the local Gateway URL and optional OpenClaw config path
 *  - `resolve-openclaw-config.ps1` for Windows + WSL config discovery
 *  - A valid OpenClaw config containing `gateway.auth.token`
 * [OUT] Outputs:
 *  - Sets `OPENCLAW_GATEWAY_URL` and `OPENCLAW_GATEWAY_TOKEN` in the current shell
 *  - Prints a short token fingerprint and the authenticated Control UI URL
 * [POS] Position in the system:
 *  - Bootstraps local shell environment for Capability Hub and other Gateway clients
 *  - Does not start the Gateway or modify OpenClaw config on disk
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>
param(
  [string]$GatewayUrl = "http://127.0.0.1:18789",
  [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Dot-source the shared config resolver (Windows + WSL fallback)
. (Join-Path $PSScriptRoot "resolve-openclaw-config.ps1")

function Get-ControlUiUrl([string]$BaseUrl, [string]$GatewayToken) {
  $normalizedBaseUrl = $BaseUrl.TrimEnd("/")
  if ([string]::IsNullOrWhiteSpace($GatewayToken)) {
    return "$normalizedBaseUrl/"
  }

  return "$normalizedBaseUrl/?token=$([uri]::EscapeDataString($GatewayToken.Trim()))"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  # Auto-resolve: try Windows first, then WSL
  $resolved = Resolve-OpenClawConfig
  if (-not $resolved.Path) {
    throw "OpenClaw config not found on Windows (%USERPROFILE%\.openclaw\openclaw.json) or in WSL (~/.openclaw/openclaw.json). Install OpenClaw and run: openclaw configure --section gateway"
  }
  $ConfigPath = $resolved.Path
  Write-Output "Config resolved from $($resolved.Source): $ConfigPath"
} else {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "OpenClaw config not found: $ConfigPath"
  }
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.gateway -or -not $cfg.gateway.auth -or -not $cfg.gateway.auth.token) {
  throw "Missing gateway.auth.token in $ConfigPath (run: openclaw configure --section gateway)"
}

$env:OPENCLAW_GATEWAY_URL = $GatewayUrl
$env:OPENCLAW_GATEWAY_TOKEN = $cfg.gateway.auth.token

# Avoid echoing secrets; show only a short fingerprint.
$t = [string]$env:OPENCLAW_GATEWAY_TOKEN
$suffix = if ($t.Length -ge 6) { $t.Substring($t.Length - 6) } else { "******" }
Write-Output "OPENCLAW env set for this shell: OPENCLAW_GATEWAY_URL=$GatewayUrl, OPENCLAW_GATEWAY_TOKEN=***$suffix"
Write-Output "Control UI URL: $(Get-ControlUiUrl -BaseUrl $GatewayUrl -GatewayToken $env:OPENCLAW_GATEWAY_TOKEN)"
