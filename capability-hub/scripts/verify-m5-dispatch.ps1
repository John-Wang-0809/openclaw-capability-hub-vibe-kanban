<#
[IN] M5 policy/bindings + m5-dispatch-client.js + vibe-kanban API + OpenClaw runtime readiness checker + optional OpenClaw CLI trigger.
[IN] Prefers `vk-bindings.local.json` when present and falls back to the tracked `vk-bindings.json` template.
[OUT] JSON verification report + process exit code.
[POS] Acceptance gate for M5 tool-mode and chat-path reverse-orchestration checks.
#>
param(
  [ValidateSet("tool", "e2e")]
  [string]$Mode = "tool",
  [string]$VkApiBaseUrl = "http://127.0.0.1:3001",
  [string]$GatewayUrl = "http://127.0.0.1:18789",
  [string]$ProjectId = "",
  [int]$TimeoutSec = 60,
  [ValidateSet("auto", "manual")]
  [string]$TriggerMode = "auto",
  [string]$SessionId = "m5-verify-e2e",
  [string]$OutputPath = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubDir = Split-Path -Parent $scriptDir
$clientScript = Join-Path $scriptDir "m5-dispatch-client.js"
$contractScript = Join-Path $scriptDir "check-m5-openclaw-contract.ps1"
$policyPath = Join-Path $hubDir "config\m5-dispatch-policy.json"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $hubDir "m5-verify-report.json"
}
function Resolve-BindingsPath([string]$HubDir) {
  $candidates = @(
    (Join-Path $HubDir "vk-bindings.local.json"),
    (Join-Path $HubDir "vk-bindings.json")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $candidates[$candidates.Count - 1]
}
function Parse-JsonLine([object]$Output) {
  $lines = @()
  foreach ($entry in @($Output)) {
    if ($null -eq $entry) { continue }
    foreach ($line in $entry.ToString().Split("`n")) {
      $trim = $line.Trim()
      if ($trim) { $lines += $trim }
    }
  }
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    try { return ($lines[$i] | ConvertFrom-Json) } catch { continue }
  }
  return $null
}
function Invoke-VkGet([string]$Path) {
  $url = "$VkApiBaseUrl$Path"
  return Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 20 -ErrorAction Stop
}
function Invoke-M5Client([string[]]$CommandArgs) {
  $prevEncoding = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  try {
    $out = & node @CommandArgs
    $code = $LASTEXITCODE
    return [ordered]@{
      exit_code = $code
      json = Parse-JsonLine -Output $out
      output = $out
    }
  } finally {
    [Console]::OutputEncoding = $prevEncoding
  }
}
function Invoke-OpenClawAgent([string]$Message, [string]$TargetSessionId) {
  $stdout = Join-Path $env:TEMP ("m5-openclaw-agent-" + [guid]::NewGuid().ToString() + ".out.log")
  $stderr = Join-Path $env:TEMP ("m5-openclaw-agent-" + [guid]::NewGuid().ToString() + ".err.log")
  $cmdLine = 'openclaw.cmd agent --session-id "' + $TargetSessionId + '" --message "' + ($Message -replace '"', '\"') + '" --json'
  $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", $cmdLine) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $outParts = @()
  if (Test-Path -LiteralPath $stdout) { $outParts += Get-Content -LiteralPath $stdout -Raw -Encoding UTF8 }
  if (Test-Path -LiteralPath $stderr) { $outParts += Get-Content -LiteralPath $stderr -Raw -Encoding UTF8 }
  $code = $proc.ExitCode
  return [ordered]@{
    exit_code = $code
    output = (($outParts -join [Environment]::NewLine).Trim())
  }
}
$diagnostics = [ordered]@{}
$failureReason = $null
$decisionPath = $null
$tasksCreated = 0
$attemptsObserved = 0
$overallOk = $false
$askToolRegistered = $false
$dispatchToolRegistered = $false
$bindingsPath = Resolve-BindingsPath -HubDir $hubDir
if (-not (Test-Path -LiteralPath $policyPath)) { throw "Missing policy file: $policyPath" }
if (-not (Test-Path -LiteralPath $bindingsPath)) { throw "Missing bindings file: $bindingsPath" }
if (-not (Test-Path -LiteralPath $clientScript)) { throw "Missing client script: $clientScript" }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$bindings = Get-Content -LiteralPath $bindingsPath -Raw | ConvertFrom-Json
$policyValid = $true
if (-not $policy.prefix) { $policyValid = $false }
if (-not $policy.routing_rules -or @($policy.routing_rules).Count -lt 1) { $policyValid = $false }
if (-not $policy.subtask_limits) { $policyValid = $false }
$bindingsValid = $true
if (-not $bindings.defaultProjectId) { $bindingsValid = $false }
if (-not $bindings.defaultExecutorProfileId) { $bindingsValid = $false }
if (-not $bindings.repoBindings -or @($bindings.repoBindings).Count -lt 1) { $bindingsValid = $false }
if ([string]::IsNullOrWhiteSpace($ProjectId)) {
  $ProjectId = [string]$bindings.defaultProjectId
}
$diagnostics.policy_path = $policyPath
$diagnostics.bindings_path = $bindingsPath
$diagnostics.default_executor = [string]$bindings.defaultExecutorProfileId
$diagnostics.project_id = $ProjectId
$listArgs = @(
  $clientScript,
  "--mode", "list-tools",
  "--gateway-url", $GatewayUrl
)
$listCall = Invoke-M5Client -CommandArgs $listArgs
if ($listCall.exit_code -eq 0 -and $listCall.json) {
  $askToolRegistered = [bool]$listCall.json.ask_tool_registered
  $dispatchToolRegistered = [bool]$listCall.json.dispatch_tool_registered
  $diagnostics.registered_tools = $listCall.json.tools
} else {
  $failureReason = "list_tools_failed"
  $diagnostics.list_tools_output = $listCall.output
}
if (-not $failureReason -and $Mode -eq "tool") {
  $subtasksPath = Join-Path $env:TEMP "m5-verify-subtasks.json"
  @(
    @{ title = "修复 capability-hub 文档细节"; description = "生成修复说明" }
    @{ title = "补充测试脚本说明"; description = "更新验证步骤" }
  ) | ConvertTo-Json -Depth 8 | Out-File -FilePath $subtasksPath -Encoding UTF8
  $dispatchArgs = @(
    $clientScript,
    "--mode", "dispatch",
    "--gateway-url", $GatewayUrl,
    "--goal", "M5 tool verify: create doc and test subtasks",
    "--trace-id", "m5-verify-tool",
    "--subtasks-file", $subtasksPath,
    "--idempotency-key", ("m5-verify-tool-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  )
  if (-not [string]::IsNullOrWhiteSpace($ProjectId)) {
    $dispatchArgs += @("--project-id", $ProjectId)
  }
  $dispatchCall = Invoke-M5Client -CommandArgs $dispatchArgs
  if ($dispatchCall.exit_code -ne 0 -or -not $dispatchCall.json) {
    $failureReason = "dispatch_call_failed"
    $diagnostics.dispatch_output = $dispatchCall.output
  } else {
    $payload = $dispatchCall.json
    $decisionPath = "tool_direct"
    $tasksCreated = @($payload.subtasks_created).Count
    $diagnostics.dispatch = $payload
    if (-not [bool]$payload.ok) {
      $failureReason = "dispatch_result_not_ok"
    } elseif ($tasksCreated -lt 1) {
      $failureReason = "dispatch_created_zero_tasks"
    } else {
      $taskIds = @($payload.subtasks_created | ForEach-Object { [string]$_.task_id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $deadline = (Get-Date).AddSeconds([Math]::Max(10, [Math]::Min($TimeoutSec, 90)))
      $lastAttemptError = $null
      while ((Get-Date) -lt $deadline) {
        foreach ($taskId in $taskIds) {
          try {
            $attemptResp = Invoke-VkGet "/api/task-attempts?task_id=$taskId"
            $attemptCount = if ($attemptResp -and $null -ne $attemptResp.data) { @($attemptResp.data).Length } else { 0 }
            if ($attemptCount -gt 0) {
              $attemptsObserved = $attemptCount
              break
            }
          } catch {
            $lastAttemptError = $_.Exception.Message
            $attemptsObserved = 0
          }
        }
        if ($attemptsObserved -gt 0) { break }
        Start-Sleep -Seconds 2
      }
      if ($lastAttemptError) {
        $diagnostics.attempt_poll_error = $lastAttemptError
      }
      if ($attemptsObserved -lt 1) {
        $failureReason = "attempt_not_observed"
      }
    }
  }
}
if (-not $failureReason -and $Mode -eq "e2e") {
  if (-not (Test-Path -LiteralPath $contractScript)) {
    $failureReason = "contract_checker_missing"
  } else {
    $contractOut = (& $contractScript | Out-String)
    $contractCode = $LASTEXITCODE
    $contractJson = $null
    try {
      $contractJson = ($contractOut.Trim() | ConvertFrom-Json)
    } catch {
      $contractJson = $null
    }
    $diagnostics.contract_check = $contractJson
    $contractOk = ($null -ne $contractJson -and ($contractJson.PSObject.Properties.Name -contains "ok") -and [bool]$contractJson.ok)
    if ($contractCode -ne 0 -or -not $contractOk) {
      $failureReason = "skill_not_ready"
    } else {
      $decisionPath = "openclaw_skill_command"
      $beforeResp = Invoke-VkGet "/api/tasks?project_id=$ProjectId"
      $beforeIds = @()
      if ($beforeResp -and $beforeResp.data) {
        $beforeIds = @($beforeResp.data | ForEach-Object { [string]$_.id })
      }
      $expectedMarker = "m5 verification"
      $triggerMessage = "/plan2vk create two M5 verification tasks"
      if ($TriggerMode -eq "manual") {
        Write-Host "[M5 e2e] Please send '$triggerMessage' in OpenClaw now..."
      } else {
        Write-Host "[M5 e2e] Sending '$triggerMessage' via OpenClaw CLI..."
        $trigger = Invoke-OpenClawAgent -Message $triggerMessage -TargetSessionId $SessionId
        $diagnostics.chat_trigger = [ordered]@{
          mode = $TriggerMode
          session_id = $SessionId
          exit_code = $trigger.exit_code
          output = $trigger.output.Trim()
        }
        if ($trigger.exit_code -ne 0) {
          $failureReason = "chat_trigger_failed"
        }
      }
      $deadline = (Get-Date).AddSeconds($TimeoutSec)
      $newTask = $null
      while (-not $failureReason -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $afterResp = Invoke-VkGet "/api/tasks?project_id=$ProjectId"
        $items = if ($afterResp -and $afterResp.data) { @($afterResp.data) } else { @() }
        $candidate = $items | Where-Object {
          $id = [string]$_.id
          $title = [string]$_.title
          ($beforeIds -notcontains $id) -and $title.ToLower().Contains($expectedMarker)
        } | Select-Object -First 1
        if ($candidate) {
          $newTask = $candidate
          break
        }
      }
      if (-not $failureReason -and -not $newTask) {
        $failureReason = "orchestrator_not_triggered"
      } elseif (-not $failureReason) {
        $tasksCreated = 1
        $taskId = [string]$newTask.id
        $attemptResp = Invoke-VkGet "/api/task-attempts?task_id=$taskId"
        $attemptsObserved = if ($attemptResp -and $null -ne $attemptResp.data) { @($attemptResp.data).Length } else { 0 }
        if ($attemptsObserved -lt 1) {
          $failureReason = "attempt_not_observed"
        }
      }
    }
  }
}
$overallOk = -not $failureReason -and $policyValid -and $bindingsValid -and $askToolRegistered -and $dispatchToolRegistered -and $tasksCreated -gt 0 -and $attemptsObserved -gt 0
if (-not $overallOk -and -not $failureReason) {
  $failureReason = "unknown_failure"
}
$report = [ordered]@{
  timestamp = [DateTime]::UtcNow.ToString("o")
  mode = $Mode
  policy_valid = $policyValid
  bindings_valid = $bindingsValid
  ask_tool_registered = $askToolRegistered
  dispatch_tool_registered = $dispatchToolRegistered
  decision_path = $decisionPath
  tasks_created = $tasksCreated
  attempts_observed = $attemptsObserved
  overall_ok = $overallOk
  failure_reason = $failureReason
  diagnostics = $diagnostics
}
$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$report | ConvertTo-Json -Depth 12 | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "M5 verify report => $OutputPath"
Write-Host ($report | ConvertTo-Json -Depth 8)
if ($overallOk) { exit 0 }
exit 1
