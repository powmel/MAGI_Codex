Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")

Import-Module (Join-Path $repoRoot "src" "MagiPipeline.psm1")

$configPath = Join-Path $repoRoot "configs" "pipeline-settings.json"
if (-not (Test-Path -LiteralPath $configPath)) {
  Write-Host "[FAIL] Missing config: $configPath"
  exit 1
}

$config = Get-Content -Path $configPath | ConvertFrom-Json
$dataRoot = $config.dataRoot

$env:TEMP = "F:\MAGI\temp"
$env:TMP = "F:\MAGI\temp"

$doctorPath = Join-Path $scriptRoot "doctor.ps1"
if (-not (Test-Path -LiteralPath $doctorPath)) {
  Write-Host "[FAIL] Missing doctor script: $doctorPath"
  exit 1
}

& $doctorPath -ConfigPath $configPath
if ($LASTEXITCODE -ne 0) {
  Write-Host "[FAIL] doctor.ps1 checks failed"
  exit 1
}

$requiredDirs = @(
  "F:\MAGI\data",
  "F:\MAGI\temp",
  "F:\MAGI\logs"
)

$dirsPassed = $true
foreach ($dir in $requiredDirs) {
  if (-not (Test-Path -LiteralPath $dir)) {
    try {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      Write-Host "[PASS] Ensured directory exists: $dir"
    } catch {
      Write-Host "[FAIL] Failed to create directory: $dir"
      $dirsPassed = $false
    }
  } else {
    Write-Host "[PASS] Directory exists: $dir"
  }
}

if (-not $dirsPassed) {
  Write-Host "[FAIL] Required directories missing or failed to create."
  exit 1
}

$inboxDir = Join-Path $dataRoot "inbox_wav"
$wavFile = Get-ChildItem -Path $inboxDir -Filter "*.wav" -File -ErrorAction SilentlyContinue | Select-Object -First 1

if ($wavFile) {
  Write-Host "[INFO] Found WAV for smoke test: $($wavFile.Name)"
  & (Join-Path $scriptRoot "run_nightly.ps1")
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] run_nightly.ps1 failed during smoke test"
    exit 1
  }
} else {
  Write-Host "[INFO] No WAV files in inbox_wav; skipping processing step"
}

$extractedDir = Join-Path $dataRoot "extracted"
$dailyDir = Join-Path $dataRoot "daily"

$extractedExists = Test-Path -LiteralPath $extractedDir
$dailyExists = Test-Path -LiteralPath $dailyDir

$extractedJson = if ($extractedExists) { Get-ChildItem -Path $extractedDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
$dailyJson = if ($dailyExists) { Get-ChildItem -Path $dailyDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }

$extractedPass = $null -ne $extractedJson
$dailyPass = $null -ne $dailyJson

if ($wavFile) {
  Write-Host ("[{0}] Extracted JSON present" -f (if ($extractedPass) { "PASS" } else { "FAIL" }))
  Write-Host ("[{0}] Daily JSON present" -f (if ($dailyPass) { "PASS" } else { "FAIL" }))

  if (-not ($extractedPass -and $dailyPass)) {
    Write-Host "[FAIL] Smoke test failed: outputs missing"
    exit 1
  }
} else {
  Write-Host "[PASS] Smoke test completed (no input files to process)"
}

Write-Host "[PASS] Smoke test completed"
