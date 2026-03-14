<#
 * [IN]  Dependencies/Inputs:
 *  - `resolve-openclaw-workspace.ps1` for workspace path resolution
 *  - A reachable vibe-kanban API exposing `/api/projects` and `/api/projects/{id}/repositories`
 *  - Existing optional `vk-bindings.local.json` and current `git` branch context
 * [OUT] Outputs:
 *  - Creates or updates `vk-bindings.local.json` with persisted project/repo bindings for dispatch
 *  - Auto-selects a single available project/repo pair or prompts once when multiple pairs exist
 *  - Emits a JSON summary of the chosen binding
 * [POS] Position in the system:
 *  - Bootstrap helper that turns local runtime state into a persisted dispatch bindings file
 *  - Does not start services; it assumes vibe-kanban is already reachable
 *
 * Change warning: once you modify this file’s logic, you must update this comment block,
 * and check/update the module doc (README/CLAUDE) in the containing folder; update the root
 * global map if necessary.
#>
param(
  [string]$ConfigPath = "",
  [string]$BindingsPath = "",
  [string]$VkApiBaseUrl = "http://127.0.0.1:3001",
  [string]$VkUiBaseUrl = "http://127.0.0.1:3001",
  [string]$DefaultExecutorProfileId = "CLAUDE_CODE",
  [switch]$Reconfigure,
  [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$capabilityHubDir = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "resolve-openclaw-workspace.ps1")

if ([string]::IsNullOrWhiteSpace($BindingsPath)) {
  $BindingsPath = Join-Path $capabilityHubDir "vk-bindings.local.json"
}

$VkApiBaseUrl = $VkApiBaseUrl.TrimEnd('/')
$VkUiBaseUrl = $VkUiBaseUrl.TrimEnd('/')

function Ensure-Directory([string]$PathValue) {
  if (-not (Test-Path -LiteralPath $PathValue)) {
    New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
  }
}

function Read-JsonFile([string]$PathValue, $FallbackValue) {
  try {
    return Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json
  } catch {
    return $FallbackValue
  }
}

function Write-Utf8NoBom([string]$PathValue, [string]$Content) {
  Ensure-Directory (Split-Path -Parent $PathValue)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($PathValue, $Content, $encoding)
}

function Invoke-VkGet([string]$PathValue) {
  $response = Invoke-RestMethod -Method Get -Uri ($VkApiBaseUrl + $PathValue) -TimeoutSec 20 -ErrorAction Stop
  if ($null -eq $response) { throw "Empty vibe-kanban response for $PathValue" }
  if (($response.PSObject.Properties.Name -contains "success") -and (-not [bool]$response.success)) {
    throw ("vibe-kanban returned success=false for {0}: {1}" -f $PathValue, [string]$response.message)
  }
  if ($response.PSObject.Properties.Name -contains "data") {
    return @($response.data)
  }
  return @($response)
}

function Get-CurrentWorkspaceBranch([pscustomobject]$WorkspaceContext) {
  if ([string]::IsNullOrWhiteSpace($WorkspaceContext.workspace_path)) { return "main" }

  if ($WorkspaceContext.runtime_platform -eq "wsl" -and $WorkspaceContext.workspace_raw.StartsWith('/')) {
    try {
      $branch = wsl -e git -C $WorkspaceContext.workspace_raw branch --show-current 2>$null | Out-String
      $trimmed = [string]$branch
      $trimmed = $trimmed.Trim()
      if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        return $trimmed
      }
    } catch {
      # ignore
    }
  }

  try {
    $branch = git -C $WorkspaceContext.workspace_path branch --show-current 2>$null | Out-String
    $trimmed = [string]$branch
    $trimmed = $trimmed.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
      return $trimmed
    }
  } catch {
    # ignore
  }

  return "main"
}

function Get-ProjectRepoPairs() {
  $pairs = New-Object System.Collections.Generic.List[object]
  $projects = Invoke-VkGet "/api/projects"
  foreach ($project in @($projects)) {
    $projectId = [string]$project.id
    if ([string]::IsNullOrWhiteSpace($projectId)) { continue }
    $projectName = [string]$project.name
    $repos = Invoke-VkGet ("/api/projects/{0}/repositories" -f [uri]::EscapeDataString($projectId))
    foreach ($repo in @($repos)) {
      $repoId = [string]$repo.id
      if ([string]::IsNullOrWhiteSpace($repoId)) { continue }
      $repoName = [string]$repo.display_name
      if ([string]::IsNullOrWhiteSpace($repoName)) {
        $repoName = [string]$repo.name
      }
      if ([string]::IsNullOrWhiteSpace($repoName)) {
        $repoName = [string]$repo.path
      }
      $pairs.Add([pscustomobject]@{
        project_id = $projectId
        project_name = $projectName
        repo_id = $repoId
        repo_name = $repoName
        repo_path = [string]$repo.path
      })
    }
  }
  return $pairs.ToArray()
}

function Find-ExistingPair([object]$BindingsObject, [object[]]$CandidatePairs) {
  $projectId = [string]$BindingsObject.defaultProjectId
  $repoBinding = @($BindingsObject.repoBindings | Where-Object { $_ }) | Select-Object -First 1
  $repoId = if ($repoBinding) { [string]$repoBinding.repoId } else { "" }
  if ([string]::IsNullOrWhiteSpace($projectId) -or [string]::IsNullOrWhiteSpace($repoId)) {
    return $null
  }

  return @($CandidatePairs | Where-Object {
      ([string]$_.project_id -eq $projectId) -and ([string]$_.repo_id -eq $repoId)
    } | Select-Object -First 1)[0]
}

function Prompt-ForPair([object[]]$CandidatePairs) {
  Write-Host ""
  Write-Host "Choose the vibe-kanban project/repository to remember for `/plan2vk`:" -ForegroundColor Cyan
  for ($index = 0; $index -lt $CandidatePairs.Count; $index++) {
    $pair = $CandidatePairs[$index]
    Write-Host ("[{0}] {1} / {2}" -f ($index + 1), $pair.project_name, $pair.repo_name)
  }

  while ($true) {
    $answer = Read-Host ("Enter a number (1-{0})" -f $CandidatePairs.Count)
    $selectedIndex = 0
    if ([int]::TryParse($answer, [ref]$selectedIndex)) {
      if ($selectedIndex -ge 1 -and $selectedIndex -le $CandidatePairs.Count) {
        return $CandidatePairs[$selectedIndex - 1]
      }
    }
    Write-Warning "Invalid selection. Enter one of the listed numbers."
  }
}

$workspaceContext = Resolve-OpenClawWorkspaceContext -ConfigPath $ConfigPath
if (-not $workspaceContext.ok) {
  throw $workspaceContext.error
}

$existingBindings = Read-JsonFile -PathValue $BindingsPath -FallbackValue ([pscustomobject]@{})
$pairs = Get-ProjectRepoPairs
if (@($pairs).Count -lt 1) {
  throw "No usable vibe-kanban project/repository pair is available at $VkApiBaseUrl. Create or link a project with at least one repository in vibe-kanban, then rerun the user-flow command."
}

$selectedPair = $null
if (-not $Reconfigure) {
  $selectedPair = Find-ExistingPair -BindingsObject $existingBindings -CandidatePairs $pairs
}

if (-not $selectedPair) {
  if (@($pairs).Count -eq 1) {
    $selectedPair = $pairs[0]
    Write-Host ("Auto-selected the only available project/repository: {0} / {1}" -f $selectedPair.project_name, $selectedPair.repo_name) -ForegroundColor Green
  } else {
    $selectedPair = Prompt-ForPair -CandidatePairs $pairs
  }
} else {
  Write-Host ("Reusing saved project/repository: {0} / {1}" -f $selectedPair.project_name, $selectedPair.repo_name) -ForegroundColor Green
}

$targetBranch = Get-CurrentWorkspaceBranch -WorkspaceContext $workspaceContext
$defaultExecutor = if (-not [string]::IsNullOrWhiteSpace([string]$existingBindings.defaultExecutorProfileId)) {
  [string]$existingBindings.defaultExecutorProfileId
} else {
  $DefaultExecutorProfileId
}

$bindingsObject = [ordered]@{
  vkUiBaseUrl = $VkUiBaseUrl
  defaultProjectId = [string]$selectedPair.project_id
  repoBindings = @(
    [ordered]@{
      targetBranch = $targetBranch
      workspacePath = [string]$workspaceContext.workspace_path
      repoId = [string]$selectedPair.repo_id
    }
  )
  vkApiBaseUrl = $VkApiBaseUrl
  defaultExecutorProfileId = $defaultExecutor
}

$json = $bindingsObject | ConvertTo-Json -Depth 8
Write-Utf8NoBom -PathValue $BindingsPath -Content ($json + "`r`n")

$result = [ordered]@{
  ok = $true
  bindings_path = $BindingsPath
  selected_project_id = [string]$selectedPair.project_id
  selected_project_name = [string]$selectedPair.project_name
  selected_repo_id = [string]$selectedPair.repo_id
  selected_repo_name = [string]$selectedPair.repo_name
  target_branch = $targetBranch
  workspace_path = [string]$workspaceContext.workspace_path
  reconfigured = [bool]$Reconfigure
}

$resultJson = $result | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  Write-Utf8NoBom -PathValue $OutputPath -Content ($resultJson + "`r`n")
}

Write-Output $resultJson
exit 0
