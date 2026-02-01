Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")

$configPath = Join-Path $repoRoot "configs" "pipeline-settings.json"
$doctorPath = Join-Path $scriptRoot "doctor.ps1"
$nightlyPath = Join-Path $scriptRoot "run_nightly.ps1"

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

$dataRoot = "F:\MAGI\data"
$tempRoot = "F:\MAGI\temp"
$logRoot = "F:\MAGI\logs"
$inboxDir = Join-Path $dataRoot "inbox_wav"
$extractedDir = Join-Path $dataRoot "extracted"
$dailyDir = Join-Path $dataRoot "daily"

$env:TEMP = $tempRoot
$env:TMP = $tempRoot

Write-Host "MAGI Smoke Test"
Write-Host "----------------"

if (-not (Test-Path -LiteralPath $doctorPath)) {
  Add-Failure "Missing doctor script at $doctorPath"
}

if (-not (Test-Path -LiteralPath $nightlyPath)) {
  Add-Failure "Missing run_nightly script at $nightlyPath"
}

foreach ($dir in @($dataRoot, $tempRoot, $logRoot, $inboxDir, $extractedDir, $dailyDir)) {
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}
Add-Pass "Required directories exist"

if ($failures.Count -eq 0) {
  & $doctorPath -ConfigPath $configPath
  if ($LASTEXITCODE -ne 0) {
    Add-Failure "Doctor checks failed"
  } else {
    Add-Pass "Doctor checks passed"
  }
}

$heldDir = Join-Path $tempRoot "smoke_hold"
$heldFiles = @()

try {
  $audioFiles = Get-ChildItem -LiteralPath $inboxDir -Filter "*.wav" -File -ErrorAction SilentlyContinue
  if ($audioFiles -and $audioFiles.Count -gt 0) {
    $primary = $audioFiles | Select-Object -First 1
    $remaining = $audioFiles | Select-Object -Skip 1

    if ($remaining) {
      if (-not (Test-Path -LiteralPath $heldDir)) {
        New-Item -ItemType Directory -Path $heldDir -Force | Out-Null
      }

      foreach ($file in $remaining) {
        $destination = Join-Path $heldDir $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $destination -Force
        $heldFiles += $destination
      }
    }

    & $nightlyPath
    if ($LASTEXITCODE -ne 0) {
      Add-Failure "Nightly pipeline failed"
    } else {
      Add-Pass "Nightly pipeline completed"
    }
  } else {
    Write-Host "[INFO] No WAV files found in inbox_wav; skipping processing."
  }
}
finally {
  foreach ($heldFile in $heldFiles) {
    if (Test-Path -LiteralPath $heldFile) {
      Move-Item -LiteralPath $heldFile -Destination $inboxDir -Force
    }
  }

  if (Test-Path -LiteralPath $heldDir) {
    Remove-Item -LiteralPath $heldDir -Force -Recurse -ErrorAction SilentlyContinue
  }
}

$extractedFiles = Get-ChildItem -LiteralPath $extractedDir -Filter "*.json" -File -ErrorAction SilentlyContinue
$dailyFiles = Get-ChildItem -LiteralPath $dailyDir -Filter "*.json" -File -ErrorAction SilentlyContinue

if ($extractedFiles -and $dailyFiles) {
  Add-Pass "JSON outputs found in extracted and daily"
  $latestExtracted = $extractedFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $latestDaily = $dailyFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $schemaExtracted = Join-Path $repoRoot "configs" "extracted.schema.json"
  $schemaDaily = Join-Path $repoRoot "configs" "daily.schema.json"
  Test-JsonWithSchema -JsonPath $latestExtracted.FullName -SchemaPath $schemaExtracted -Label "Extracted"
  Test-JsonWithSchema -JsonPath $latestDaily.FullName -SchemaPath $schemaDaily -Label "Daily"
} else {
  Add-Failure "JSON outputs missing in extracted or daily"
}

Write-Host ""
if ($failures.Count -gt 0) {
  Write-Host "Smoke test failed:"
  foreach ($failure in $failures) {
    Write-Host ("- {0}" -f $failure)
  }
  exit 1
}

Write-Host "Smoke test passed."
