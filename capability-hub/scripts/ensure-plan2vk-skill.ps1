<#
 * [IN]  Dependencies/Inputs:
 *  - `resolve-openclaw-workspace.ps1` for workspace path resolution across Windows and WSL
 *  - Repo-managed templates under `capability-hub/templates/plan2vk/`
 *  - `check-m5-openclaw-contract.ps1` for post-install verification
 *  - A writable OpenClaw workspace with `skills/` and optional `AGENTS.md`
 * [OUT] Outputs:
 *  - Installs or updates the managed `skills/plan2vk/SKILL.md` file in the resolved OpenClaw workspace
 *  - Replaces or appends the managed `/plan2vk` fallback block inside workspace `AGENTS.md`
 *  - Emits a JSON summary and exits non-zero if the installed skill still fails contract verification
 * [POS] Position in the system:
 *  - Bootstrap helper that turns the repo-managed `/plan2vk` template into a workspace-local OpenClaw skill
 *  - Does not start the gateway or dispatch tasks; it only manages the local skill and fallback note
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>
param(
  [string]$ConfigPath = "",
  [string]$GatewayUrl = "http://127.0.0.1:18789",
  [string]$CapabilityHubDir = "",
  [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "resolve-openclaw-workspace.ps1")

if ([string]::IsNullOrWhiteSpace($CapabilityHubDir)) {
  $CapabilityHubDir = Split-Path -Parent $scriptDir
}

$managedSkillMarker = "<!-- managed-by: openclaw-capability-hub-vibe-kanban /plan2vk -->"
$managedAgentsBegin = "<!-- BEGIN openclaw-capability-hub-vibe-kanban:plan2vk -->"
$managedAgentsEnd = "<!-- END openclaw-capability-hub-vibe-kanban:plan2vk -->"
$templatesDir = Join-Path $CapabilityHubDir "templates\plan2vk"
$skillTemplatePath = Join-Path $templatesDir "SKILL.md.template"
$agentsTemplatePath = Join-Path $templatesDir "AGENTS.block.template.md"
$contractScript = Join-Path $scriptDir "check-m5-openclaw-contract.ps1"

function Ensure-Directory([string]$PathValue) {
  if (-not (Test-Path -LiteralPath $PathValue)) {
    New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
  }
}

function Read-Utf8File([string]$PathValue) {
  return [System.IO.File]::ReadAllText($PathValue, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom([string]$PathValue, [string]$Content) {
  Ensure-Directory (Split-Path -Parent $PathValue)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($PathValue, $Content, $encoding)
}

function Get-NewlineStyle([string]$Content) {
  if ($null -ne $Content -and $Content.Contains("`r`n")) {
    return "`r`n"
  }
  return "`n"
}

function Normalize-Newlines([string]$Content, [string]$Newline) {
  if ([string]::IsNullOrEmpty($Content)) { return "" }
  $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
  if ($Newline -eq "`n") {
    return $normalized
  }
  return ($normalized -replace "`n", $Newline)
}

function Escape-Replacement([string]$Value) {
  return $Value -replace '\$', '$$'
}

function Render-Template([string]$TemplatePath, [hashtable]$Variables) {
  $content = Read-Utf8File $TemplatePath
  foreach ($entry in $Variables.GetEnumerator()) {
    $token = [regex]::Escape("{{" + $entry.Key + "}}")
    $replacement = Escape-Replacement ([string]$entry.Value)
    $content = [regex]::Replace($content, $token, $replacement)
  }
  return $content
}

function Update-ManagedBlock([string]$ExistingContent, [string]$ManagedBlock) {
  $newline = if ([string]::IsNullOrWhiteSpace($ExistingContent)) { "`r`n" } else { Get-NewlineStyle $ExistingContent }
  $normalizedManagedBlock = Normalize-Newlines -Content $ManagedBlock -Newline $newline

  if ([string]::IsNullOrWhiteSpace($ExistingContent)) {
    return "# AGENTS.md - Workspace${newline}${newline}${normalizedManagedBlock}${newline}"
  }

  $normalizedExistingContent = Normalize-Newlines -Content $ExistingContent -Newline $newline
  $beginPattern = [regex]::Escape($managedAgentsBegin)
  $endPattern = [regex]::Escape($managedAgentsEnd)
  $managedPattern = "(?s)$beginPattern.*?$endPattern"
  if ([regex]::IsMatch($normalizedExistingContent, $managedPattern)) {
    $replaced = [regex]::Replace($normalizedExistingContent, $managedPattern, (Escape-Replacement $normalizedManagedBlock))
    if ($replaced.TrimEnd("`r", "`n") -eq $normalizedExistingContent.TrimEnd("`r", "`n")) {
      return $normalizedExistingContent
    }
    return $replaced
  }

  $trimmed = $normalizedExistingContent.TrimEnd("`r", "`n")
  return "$trimmed${newline}${newline}${normalizedManagedBlock}${newline}"
}

function Backup-IfNeeded([string]$PathValue, [string]$Content) {
  if (-not (Test-Path -LiteralPath $PathValue)) { return "" }
  if ($Content -like "*$managedSkillMarker*") { return "" }
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backupPath = "$PathValue.backup.$timestamp"
  Copy-Item -LiteralPath $PathValue -Destination $backupPath -Force
  return $backupPath
}

function Invoke-ContractVerification([string]$ResolvedConfigPath, [string]$RuntimeMode) {
  $attempts = 5
  for ($index = 0; $index -lt $attempts; $index++) {
    $output = & $contractScript -ConfigPath $ResolvedConfigPath -Runtime $RuntimeMode 2>&1 | Out-String
    $code = $LASTEXITCODE
    $json = $null
    try {
      $json = ($output.Trim() | ConvertFrom-Json)
    } catch {
      $json = $null
    }
    $ok = ($code -eq 0 -and $null -ne $json -and ($json.PSObject.Properties.Name -contains "ok") -and [bool]$json.ok)
    if ($ok) {
      return [pscustomobject]@{
        ok = $true
        exit_code = $code
        output = $output.Trim()
        json = $json
      }
    }
    Start-Sleep -Seconds 1
  }

  return [pscustomobject]@{
    ok = $false
    exit_code = $LASTEXITCODE
    output = $output.Trim()
    json = $json
  }
}

if (-not (Test-Path -LiteralPath $skillTemplatePath)) {
  throw "Managed skill template not found: $skillTemplatePath"
}
if (-not (Test-Path -LiteralPath $agentsTemplatePath)) {
  throw "Managed AGENTS template not found: $agentsTemplatePath"
}
if (-not (Test-Path -LiteralPath $contractScript)) {
  throw "Contract checker not found: $contractScript"
}

$workspaceContext = Resolve-OpenClawWorkspaceContext -ConfigPath $ConfigPath
if (-not $workspaceContext.ok) {
  throw $workspaceContext.error
}

$hubDirWindows = [System.IO.Path]::GetFullPath($CapabilityHubDir)
$hubDirRuntime = if ($workspaceContext.runtime_platform -eq "wsl") {
  Convert-WindowsPathToWsl $hubDirWindows
} else {
  $hubDirWindows
}
$subtasksFile = if ($workspaceContext.runtime_platform -eq "wsl") {
  (Convert-WindowsPathToWsl (Join-Path $hubDirWindows "plan2vk-subtasks.json"))
} else {
  (Join-Path $hubDirWindows "plan2vk-subtasks.json")
}
$clientScriptPath = if ($workspaceContext.runtime_platform -eq "wsl") {
  (Convert-WindowsPathToWsl (Join-Path $hubDirWindows "scripts\m5-dispatch-client.js"))
} else {
  (Join-Path $hubDirWindows "scripts\m5-dispatch-client.js")
}

$variables = @{
  MANAGED_MARKER = $managedSkillMarker
  HUB_DIR = $hubDirRuntime
  GATEWAY_URL = $GatewayUrl
  SUBTASKS_FILE = $subtasksFile
  CLIENT_SCRIPT = $clientScriptPath
  AGENTS_BEGIN = $managedAgentsBegin
  AGENTS_END = $managedAgentsEnd
}

$renderedSkill = Render-Template -TemplatePath $skillTemplatePath -Variables $variables
$renderedAgentsBlock = Render-Template -TemplatePath $agentsTemplatePath -Variables $variables

$skillsDir = Join-Path $workspaceContext.workspace_path "skills"
$skillDir = Join-Path $skillsDir "plan2vk"
$skillPath = Join-Path $skillDir "SKILL.md"
$agentsPath = Join-Path $workspaceContext.workspace_path "AGENTS.md"

Ensure-Directory $skillDir
$existingSkillContent = if (Test-Path -LiteralPath $skillPath) { Read-Utf8File $skillPath } else { "" }
$backupPath = Backup-IfNeeded -PathValue $skillPath -Content $existingSkillContent
$skillChanged = ($existingSkillContent -ne $renderedSkill)
if ($skillChanged) {
  Write-Utf8NoBom -PathValue $skillPath -Content $renderedSkill
}

$existingAgentsContent = if (Test-Path -LiteralPath $agentsPath) { Read-Utf8File $agentsPath } else { "" }
$updatedAgentsContent = Update-ManagedBlock -ExistingContent $existingAgentsContent -ManagedBlock $renderedAgentsBlock
$agentsChanged = ($existingAgentsContent -ne $updatedAgentsContent)
if ($agentsChanged) {
  Write-Utf8NoBom -PathValue $agentsPath -Content $updatedAgentsContent
}

$runtimeMode = if ($workspaceContext.runtime_platform -eq "wsl") { "wsl" } else { "windows" }
$contractResult = Invoke-ContractVerification -ResolvedConfigPath $workspaceContext.config_path -RuntimeMode $runtimeMode

$result = [ordered]@{
  ok = [bool]$contractResult.ok
  workspace_path = $workspaceContext.workspace_path
  runtime_platform = $workspaceContext.runtime_platform
  skill_path = $skillPath
  skill_changed = $skillChanged
  skill_backup_path = $backupPath
  agents_path = $agentsPath
  agents_changed = $agentsChanged
  contract = $contractResult.json
  contract_output = $contractResult.output
}

$json = $result | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  Ensure-Directory (Split-Path -Parent $OutputPath)
  Write-Utf8NoBom -PathValue $OutputPath -Content ($json + "`r`n")
}

Write-Output $json
if (-not $contractResult.ok) {
  exit 1
}
exit 0
