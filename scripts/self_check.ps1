Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")

$doctorPath = Join-Path $scriptRoot "doctor.ps1"
$smokePath = Join-Path $scriptRoot "smoke_test.ps1"
$schemaExtracted = Join-Path $repoRoot "configs" "extracted.schema.json"
$schemaDaily = Join-Path $repoRoot "configs" "daily.schema.json"

$failures = @()

function Add-Failure {
  param([string]$Message)
  $failures += $Message
  Write-Host ("[FAIL] {0}" -f $Message)
}

function Add-Pass {
  param([string]$Message)
  Write-Host ("[PASS] {0}" -f $Message)
}

function Test-JsonSchemaSupport {
  $command = Get-Command Test-Json -ErrorAction SilentlyContinue
  if (-not $command) {
    return $false
  }
  return $command.Parameters.ContainsKey("Schema")
}

function Test-JsonWithSchema {
  param(
    [Parameter(Mandatory = $true)][string]$JsonPath,
    [Parameter(Mandatory = $true)][string]$SchemaPath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $JsonPath)) {
    Add-Failure "$Label JSON missing at $JsonPath"
    return
  }
  if (-not (Test-Path -LiteralPath $SchemaPath)) {
    Add-Failure "$Label schema missing at $SchemaPath"
    return
  }
  if (-not (Test-JsonSchemaSupport)) {
    Add-Failure "Test-Json schema validation not available. Install PowerShell 7+."
    return
  }

  $jsonText = Get-Content -LiteralPath $JsonPath -Raw
  $schemaText = Get-Content -LiteralPath $SchemaPath -Raw
  $valid = Test-Json -Json $jsonText -Schema $schemaText -ErrorAction SilentlyContinue
  if ($valid) {
    Add-Pass "$Label JSON validated against schema"
  } else {
    Add-Failure "$Label JSON failed schema validation"
  }
}

Write-Host "MAGI Self Check"
Write-Host "---------------"

if (-not (Test-Path -LiteralPath $doctorPath)) {
  Add-Failure "Missing doctor script at $doctorPath"
} else {
  & $doctorPath -ConfigPath (Join-Path $repoRoot "configs" "pipeline-settings.json")
  if ($LASTEXITCODE -ne 0) {
    Add-Failure "Doctor checks failed"
  } else {
    Add-Pass "Doctor checks passed"
  }
}

if ($failures.Count -eq 0) {
  if (-not (Test-Path -LiteralPath $smokePath)) {
    Add-Failure "Missing smoke_test script at $smokePath"
  } else {
    & $smokePath
    if ($LASTEXITCODE -ne 0) {
      Add-Failure "Smoke test failed"
    } else {
      Add-Pass "Smoke test passed"
    }
  }
}

if ($failures.Count -eq 0) {
  $extractedDir = "F:\MAGI\data\extracted"
  $dailyDir = "F:\MAGI\data\daily"
  $latestExtracted = Get-ChildItem -LiteralPath $extractedDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $latestDaily = Get-ChildItem -LiteralPath $dailyDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

  if ($latestExtracted) {
    Test-JsonWithSchema -JsonPath $latestExtracted.FullName -SchemaPath $schemaExtracted -Label "Extracted"
  } else {
    Add-Failure "No extracted JSON found for schema validation"
  }

  if ($latestDaily) {
    Test-JsonWithSchema -JsonPath $latestDaily.FullName -SchemaPath $schemaDaily -Label "Daily"
  } else {
    Add-Failure "No daily JSON found for schema validation"
  }
}

Write-Host ""
if ($failures.Count -gt 0) {
  Write-Host "Self check failed:"
  foreach ($failure in $failures) {
    Write-Host ("- {0}" -f $failure)
  }
  exit 1
}

Write-Host "Self check passed."
