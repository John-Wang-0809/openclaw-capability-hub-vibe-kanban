<#
 * [IN]  Dependencies/Inputs:
 *  - PowerShell parameters for vibe-kanban API URL, target executors, gateway settings, and hub key
 *  - `resolve-openclaw-config.ps1` for gateway token discovery
 *  - Local `openclaw-capability-hub.js` path and a reachable vibe-kanban MCP config API
 * [OUT] Outputs:
 *  - Updates vibe-kanban MCP server configuration for each requested executor
 *  - Prints per-executor MCP injection status to the console
 * [POS] Position in the system:
 *  - Adapts Capability Hub into vibe-kanban MCP configuration for one or more executors
 *  - Does not start processes or generate vibe-kanban subtasks itself
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$VkApiBaseUrl,

  # Examples: CODEX, CLAUDE_CODE, CURSOR_AGENT, OPENCODE, GEMINI, AMP
  [Parameter(Mandatory = $true)]
  [string[]]$Executors,

  [ValidateSet("merge", "replace")]
  [string]$Mode = "merge",

  [string]$GatewayUrl = "http://127.0.0.1:18789",
  [string]$GatewayToken = "",

  [string]$HubKey = "openclaw_capability_hub"
)

<#
Usage example:
  powershell -ExecutionPolicy Bypass -File .\vk-inject-mcp.ps1 `
    -VkApiBaseUrl http://127.0.0.1:3001 `
    -Executors CODEX,CLAUDE_CODE `
    -Mode merge `
    -GatewayUrl http://127.0.0.1:18789
#>

$ErrorActionPreference = "Stop"

# Dot-source the shared config resolver (Windows + WSL fallback)
. (Join-Path $PSScriptRoot "resolve-openclaw-config.ps1")

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

$VkApiBaseUrl = $VkApiBaseUrl.TrimEnd("/")
$Executors = @(Normalize-ExecutorList $Executors)
if ($Executors.Count -eq 0) {
  throw "At least one executor must be provided. Use comma-delimited CLI input like -Executors CODEX,CLAUDE_CODE, or pass a string array from another PowerShell script."
}

$resolvedToken = $GatewayToken.Trim()
if ($resolvedToken.Length -eq 0) {
  $tokenResult = Get-OpenClawGatewayToken
  if ($tokenResult.Token) {
    $resolvedToken = $tokenResult.Token
    $suffix = if ($resolvedToken.Length -ge 6) { $resolvedToken.Substring($resolvedToken.Length - 6) } else { "******" }
    Write-Host "Gateway token loaded from $($tokenResult.Source) (***$suffix)"
  }
}

$hubScript = (Resolve-Path (Join-Path $PSScriptRoot "..\\src\\openclaw-capability-hub.js")).Path

$hubServer = @{
  command = "node"
  args    = @($hubScript)
  env     = @{
    OPENCLAW_GATEWAY_URL = $GatewayUrl
  }
}
if ($resolvedToken.Trim().Length -gt 0) {
  $hubServer.env.OPENCLAW_GATEWAY_TOKEN = $resolvedToken
}

function To-HashtableDeep($obj) {
  if ($null -eq $obj) { return $null }
  return (ConvertFrom-Json -AsHashtable (ConvertTo-Json $obj -Depth 100))
}

foreach ($executor in $Executors) {
  $executor = $executor.Trim()
  if ($executor.Length -eq 0) { continue }

  $servers = @{}
  if ($Mode -eq "merge") {
    try {
      $get = Invoke-RestMethod -Method Get -Uri "$VkApiBaseUrl/api/mcp-config?executor=$executor"
      if ($get.success -and $get.data -and $get.data.mcp_config -and $get.data.mcp_config.servers) {
        $servers = To-HashtableDeep $get.data.mcp_config.servers
      }
    } catch {
      # If the server isn't reachable or the executor has no MCP config yet, fall back to empty.
      $servers = @{}
    }
  }

  $servers[$HubKey] = $hubServer
  $body = @{ servers = $servers }
  $json = ConvertTo-Json $body -Depth 20

  Write-Host "Applying MCP server '$HubKey' to executor=$executor (mode=$Mode)..."
  $resp = Invoke-RestMethod -Method Post -Uri "$VkApiBaseUrl/api/mcp-config?executor=$executor" -ContentType "application/json" -Body $json
  if ($resp.success) {
    Write-Host "OK: $($resp.data)"
  } else {
    Write-Host "ERROR: $($resp.message)"
  }
}
