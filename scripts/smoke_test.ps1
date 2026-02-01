Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")

Import-Module (Join-Path $repoRoot "src" "MagiPipeline.psm1")

$configPath = Join-Path $repoRoot "configs" "pipeline-settings.json"
if (-not (Test-Path -LiteralPath $configPath)) {
  throw "Missing config: $configPath"
}

$env:TEMP = "F:\MAGI\temp"
$env:TMP = "F:\MAGI\temp"

$doctorPath = Join-Path $scriptRoot "doctor.ps1"
if (-not (Test-Path -LiteralPath $doctorPath)) {
  throw "Missing dependency checker: $doctorPath"
}

& $doctorPath -ConfigPath $configPath
if ($LASTEXITCODE -ne 0) {
  throw "Dependency checks failed. Resolve issues reported by scripts/doctor.ps1."
}

$dataRoot = "F:\MAGI\data"
$tempRoot = "F:\MAGI\temp"
$logRoot = "F:\MAGI\logs"

Ensure-MagiDirectory -Path $dataRoot
Ensure-MagiDirectory -Path $tempRoot
Ensure-MagiDirectory -Path $logRoot

$results = @()
function Add-Result {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $results += [pscustomobject]@{
    Name = $Name
    Passed = $Passed
    Message = $Message
  }

  $status = if ($Passed) { "PASS" } else { "FAIL" }
  Write-Host ("[{0}] {1} - {2}" -f $status, $Name, $Message)
}

Add-Result -Name "Directory setup" -Passed ($true) -Message "Ensured F:\MAGI\data, F:\MAGI\temp, F:\MAGI\logs exist"

$inboxDir = Join-Path $dataRoot "inbox_wav"
$extractedDir = Join-Path $dataRoot "extracted"
$dailyDir = Join-Path $dataRoot "daily"

Ensure-MagiDirectory -Path $inboxDir
Ensure-MagiDirectory -Path $extractedDir
Ensure-MagiDirectory -Path $dailyDir

$wavFiles = Get-ChildItem -Path $inboxDir -Filter "*.wav" -File -ErrorAction SilentlyContinue
$processed = $false
$stashDir = Join-Path $tempRoot "smoke_test_stash"
$stashedFiles = @()

try {
  if ($wavFiles -and $wavFiles.Count -gt 0) {
    $processed = $true
    $primaryFile = $wavFiles | Select-Object -First 1
    $extraFiles = $wavFiles | Select-Object -Skip 1

    if ($extraFiles) {
      Ensure-MagiDirectory -Path $stashDir
      foreach ($file in $extraFiles) {
        $destination = Join-Path $stashDir $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $destination
        $stashedFiles += $destination
      }
    }

    $startTime = Get-Date
    & (Join-Path $scriptRoot "run_nightly.ps1")

    $newExtracted = Get-ChildItem -Path $extractedDir -Filter "*.json" -File | Where-Object { $_.LastWriteTime -ge $startTime }
    $dailyPath = Join-Path $dailyDir ((Get-Date -Format "yyyy-MM-dd") + ".json")
    $dailyExists = Test-Path -LiteralPath $dailyPath
    $dailyRecent = $false
    if ($dailyExists) {
      $dailyInfo = Get-Item -LiteralPath $dailyPath
      $dailyRecent = $dailyInfo.LastWriteTime -ge $startTime
    }

    Add-Result -Name "Extracted output" -Passed ($newExtracted.Count -ge 1) -Message (if ($newExtracted.Count -ge 1) { "Extracted JSON created" } else { "No new extracted JSON found" })
    Add-Result -Name "Daily output" -Passed ($dailyExists -and $dailyRecent) -Message (if ($dailyExists -and $dailyRecent) { "Daily JSON updated" } else { "Daily JSON not updated" })
  } else {
    Add-Result -Name "Processing" -Passed ($true) -Message "No WAV files found; skipped processing"
  }
}
finally {
  if ($stashedFiles.Count -gt 0) {
    foreach ($stashed in $stashedFiles) {
      if (Test-Path -LiteralPath $stashed) {
        Move-Item -LiteralPath $stashed -Destination $inboxDir
      }
    }
    if (Test-Path -LiteralPath $stashDir) {
      Remove-Item -LiteralPath $stashDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

$failed = $results | Where-Object { -not $_.Passed }
if ($failed.Count -gt 0) {
  Write-Host "\nSmoke test failed. Resolve the failures above before running nightly pipeline."
  exit 1
}

Write-Host "\nSmoke test passed."
