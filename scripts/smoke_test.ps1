Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")

$doctorPath = Join-Path $scriptRoot "doctor.ps1"
if (-not (Test-Path -LiteralPath $doctorPath)) {
  Write-Host "[FAIL] Missing dependency checker: $doctorPath"
  exit 1
}

$configPath = Join-Path $repoRoot "configs" "pipeline-settings.json"
if (-not (Test-Path -LiteralPath $configPath)) {
  Write-Host "[FAIL] Missing config: $configPath"
  exit 1
}

& $doctorPath -ConfigPath $configPath
if ($LASTEXITCODE -ne 0) {
  Write-Host "[FAIL] Doctor checks failed. Fix dependencies before running smoke test."
  exit 1
}

$config = Get-Content -Path $configPath | ConvertFrom-Json
$dataRoot = $config.dataRoot
$tempRoot = $config.tempRoot
$logRoot = $config.logRoot

$requiredDirs = @(
  $dataRoot,
  $tempRoot,
  $logRoot,
  (Join-Path $dataRoot "inbox_wav"),
  (Join-Path $dataRoot "extracted"),
  (Join-Path $dataRoot "daily")
)

foreach ($dir in $requiredDirs) {
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

$inboxDir = Join-Path $dataRoot "inbox_wav"
$wavFiles = Get-ChildItem -Path $inboxDir -Filter "*.wav" -File -ErrorAction SilentlyContinue
$backupDir = Join-Path $tempRoot "smoke_test_backup"
$hasAudio = $false
$runPassed = $true

try {
  if ($wavFiles -and $wavFiles.Count -gt 0) {
    $hasAudio = $true
    $keepFile = $wavFiles[0]
    $backupTargets = $wavFiles | Where-Object { $_.FullName -ne $keepFile.FullName }

    if ($backupTargets) {
      if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
      }

      foreach ($file in $backupTargets) {
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $backupDir $file.Name) -Force
      }
    }

    & (Join-Path $scriptRoot "run_nightly.ps1")
    if ($LASTEXITCODE -ne 0) {
      $runPassed = $false
    }
  }
}
finally {
  if (Test-Path -LiteralPath $backupDir) {
    $backupFiles = Get-ChildItem -Path $backupDir -Filter "*.wav" -File -ErrorAction SilentlyContinue
    foreach ($file in $backupFiles) {
      Move-Item -LiteralPath $file.FullName -Destination (Join-Path $inboxDir $file.Name) -Force
    }
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$extractedDir = Join-Path $dataRoot "extracted"
$dailyDir = Join-Path $dataRoot "daily"
$extractedFiles = Get-ChildItem -Path $extractedDir -Filter "*.json" -File -ErrorAction SilentlyContinue
$dailyFiles = Get-ChildItem -Path $dailyDir -Filter "*.json" -File -ErrorAction SilentlyContinue

$outputsPass = $true
if ($hasAudio) {
  $outputsPass = ($extractedFiles.Count -gt 0) -and ($dailyFiles.Count -gt 0)
}

if (-not $runPassed) {
  Write-Host "[FAIL] run_nightly.ps1 failed"
  exit 1
}

if ($hasAudio -and -not $outputsPass) {
  Write-Host "[FAIL] Expected extracted/daily JSON outputs were not found"
  exit 1
}

if (-not $hasAudio) {
  Write-Host "[PASS] Smoke test completed (no WAV files found; outputs not generated)"
  exit 0
}

Write-Host "[PASS] Smoke test completed (outputs generated)"
