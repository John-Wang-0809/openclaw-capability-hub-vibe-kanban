<#
.SYNOPSIS
  Resolves the OpenClaw config file path, checking Windows first, then WSL.

.DESCRIPTION
  When OpenClaw is deployed in WSL2 and vibe-kanban / Capability Hub remain on
  Windows, the config file (~/.openclaw/openclaw.json) lives inside WSL.
  This helper tries, in order:
    1. Windows native path: %USERPROFILE%\.openclaw\openclaw.json
    2. WSL UNC path:        \\wsl.localhost\<distro>\home\<user>\.openclaw\openclaw.json
    3. WSL command fallback: wsl -e sh -c "cat ~/.openclaw/openclaw.json"

  If the WSL command fallback is used, the content is written to a temp file
  so callers can use standard Get-Content/ConvertFrom-Json on the returned path.

.OUTPUTS
  Hashtable with keys:
    Path    - resolved file path (or $null if not found)
    Source  - "windows", "wsl-unc", "wsl-command", or $null
#>

function Resolve-OpenClawConfig {
  param(
    [string]$WindowsPath = (Join-Path $env:USERPROFILE ".openclaw\openclaw.json")
  )

  # 1. Windows native path
  if (Test-Path -LiteralPath $WindowsPath) {
    return @{ Path = $WindowsPath; Source = "windows" }
  }

  # 2. WSL UNC path (requires detecting distro + user)
  try {
    $distroRaw = wsl -l -q 2>$null
    if ($LASTEXITCODE -eq 0 -and $distroRaw) {
      # wsl -l -q may output UTF-16 with null bytes; clean it
      $distro = ($distroRaw | Select-Object -First 1).Trim().Trim([char]0)
      if ($distro) {
        $wslUser = (wsl -d $distro -e whoami 2>$null)
        if ($LASTEXITCODE -eq 0 -and $wslUser) {
          $wslUser = $wslUser.Trim().Trim([char]0)
          # Try modern path first (\\wsl.localhost\), then legacy (\\wsl$\)
          foreach ($prefix in @("\\wsl.localhost", "\\wsl$")) {
            $uncPath = Join-Path $prefix "$distro\home\$wslUser\.openclaw\openclaw.json"
            if (Test-Path -LiteralPath $uncPath) {
              return @{ Path = $uncPath; Source = "wsl-unc" }
            }
          }
        }
      }
    }
  } catch {
    # WSL not available or errored; continue to fallback
  }

  # 3. WSL command fallback (read via stdin pipe)
  try {
    $content = wsl -e sh -c "cat ~/.openclaw/openclaw.json 2>/dev/null"
    if ($LASTEXITCODE -eq 0 -and $content) {
      $tmpPath = Join-Path $env:TEMP "openclaw-wsl-config.json"
      [System.IO.File]::WriteAllText($tmpPath, ($content -join "`n"), [System.Text.Encoding]::UTF8)
      return @{ Path = $tmpPath; Source = "wsl-command" }
    }
  } catch {
    # WSL command failed
  }

  return @{ Path = $null; Source = $null }
}

<#
.SYNOPSIS
  Reads the gateway auth token from the resolved OpenClaw config.

.OUTPUTS
  Hashtable with keys:
    Token   - the gateway.auth.token string, or empty string
    Source  - where the config was found (see Resolve-OpenClawConfig)
    Path    - the config file path used
#>
function Get-OpenClawGatewayToken {
  param(
    [string]$WindowsPath = (Join-Path $env:USERPROFILE ".openclaw\openclaw.json")
  )

  $resolved = Resolve-OpenClawConfig -WindowsPath $WindowsPath
  if (-not $resolved.Path) {
    return @{ Token = ""; Source = $null; Path = $null }
  }

  try {
    $cfg = Get-Content -LiteralPath $resolved.Path -Raw | ConvertFrom-Json
    if ($cfg.gateway -and $cfg.gateway.auth -and $cfg.gateway.auth.token) {
      return @{ Token = [string]$cfg.gateway.auth.token; Source = $resolved.Source; Path = $resolved.Path }
    }
  } catch {
    # parse error
  }

  return @{ Token = ""; Source = $resolved.Source; Path = $resolved.Path }
}
