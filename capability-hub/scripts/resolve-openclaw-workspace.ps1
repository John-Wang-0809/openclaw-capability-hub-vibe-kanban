<#
 * [IN]  Dependencies/Inputs:
 *  - `resolve-openclaw-config.ps1` for Windows/WSL OpenClaw config discovery
 *  - OpenClaw config JSON containing `agents.defaults.workspace`
 *  - Optional WSL availability for Linux-path to UNC conversion
 * [OUT] Outputs:
 *  - `Convert-WindowsPathToWsl`, `Convert-LinuxPathToUnc`, and `Resolve-OpenClawWorkspaceContext`
 *  - A resolved workspace context with raw workspace path, writable host path, and runtime hint
 * [POS] Position in the system:
 *  - Shared bootstrap helper for scripts that need the OpenClaw workspace without duplicating config parsing
 *  - Does not install or mutate OpenClaw; it only resolves paths and workspace metadata
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "resolve-openclaw-config.ps1")

function Get-DefaultWslDistro {
  try {
    $raw = wsl -l -q 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return "" }
    foreach ($line in @($raw)) {
      $clean = ($line -replace "`0", "").Trim()
      if ($clean) { return $clean }
    }
  } catch {
    # ignore
  }
  return ""
}

function Convert-LinuxPathToUnc([string]$LinuxPath, [string]$Distro = "") {
  if ([string]::IsNullOrWhiteSpace($LinuxPath) -or -not $LinuxPath.StartsWith('/')) { return "" }
  $resolvedDistro = if ([string]::IsNullOrWhiteSpace($Distro)) { Get-DefaultWslDistro } else { $Distro }
  if ([string]::IsNullOrWhiteSpace($resolvedDistro)) { return "" }

  $relative = $LinuxPath.TrimStart('/').Replace('/', '\')
  foreach ($prefix in @('\\wsl.localhost', '\\wsl$')) {
    $candidate = Join-Path $prefix "$resolvedDistro\$relative"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }

  return ""
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
  if ([string]::IsNullOrWhiteSpace($WindowsPath)) { return "" }
  $normalized = $WindowsPath.Trim() -replace '\\', '/'
  if ($normalized -match '^([A-Za-z]):/(.*)$') {
    $drive = $matches[1].ToLowerInvariant()
    $rest = $matches[2]
    if ([string]::IsNullOrWhiteSpace($rest)) {
      return "/mnt/$drive"
    }
    return "/mnt/$drive/$rest"
  }
  return $normalized
}

function Resolve-OpenClawWorkspaceContext {
  param(
    [string]$ConfigPath = ""
  )

  $resolved = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Resolve-OpenClawConfig
  } else {
    @{
      Path = $ConfigPath
      Source = "manual"
    }
  }

  if (-not $resolved.Path) {
    return [pscustomobject]@{
      ok = $false
      error = "OpenClaw config file was not found."
      config_path = ""
      config_source = [string]$resolved.Source
      workspace_raw = ""
      workspace_path = ""
      runtime_platform = ""
      wsl_distro = ""
    }
  }

  $cfg = $null
  try {
    $cfg = Get-Content -LiteralPath $resolved.Path -Raw | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{
      ok = $false
      error = "Failed to parse OpenClaw config: $($resolved.Path)"
      config_path = [string]$resolved.Path
      config_source = [string]$resolved.Source
      workspace_raw = ""
      workspace_path = ""
      runtime_platform = ""
      wsl_distro = ""
    }
  }

  $workspaceRaw = ""
  if ($cfg.agents -and $cfg.agents.defaults -and $cfg.agents.defaults.workspace) {
    $workspaceRaw = [string]$cfg.agents.defaults.workspace
  }

  if ([string]::IsNullOrWhiteSpace($workspaceRaw)) {
    return [pscustomobject]@{
      ok = $false
      error = "OpenClaw config is missing agents.defaults.workspace."
      config_path = [string]$resolved.Path
      config_source = [string]$resolved.Source
      workspace_raw = ""
      workspace_path = ""
      runtime_platform = ""
      wsl_distro = ""
    }
  }

  $wslDistro = ""
  $workspacePath = $workspaceRaw
  $runtimePlatform = "windows"
  if ($workspaceRaw.StartsWith('/')) {
    $runtimePlatform = "wsl"
    $wslDistro = Get-DefaultWslDistro
    $uncPath = Convert-LinuxPathToUnc -LinuxPath $workspaceRaw -Distro $wslDistro
    if ($uncPath) {
      $workspacePath = $uncPath
    }
  } elseif ([string]$resolved.Source -like 'wsl*') {
    $runtimePlatform = "wsl"
  }

  return [pscustomobject]@{
    ok = $true
    error = ""
    config_path = [string]$resolved.Path
    config_source = [string]$resolved.Source
    workspace_raw = $workspaceRaw
    workspace_path = $workspacePath
    runtime_platform = $runtimePlatform
    wsl_distro = $wslDistro
  }
}
