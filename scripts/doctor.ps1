Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
  [string]$ConfigPath
)

function Write-CheckResult {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Hint
  )

  $status = if ($Passed) { "PASS" } else { "FAIL" }
  Write-Host ("[{0}] {1} - {2}" -f $status, $Name, $Message)
  if (-not $Passed -and $Hint) {
    Write-Host ("  Hint: {0}" -f $Hint)
  }

  return $Passed
}

function Get-FreeSpaceGB {
  param([string]$DriveName)

  $drive = Get-PSDrive -Name $DriveName -ErrorAction SilentlyContinue
  if (-not $drive) {
    return $null
  }

  return [math]::Round($drive.Free / 1GB, 2)
}

function Resolve-ConfiguredPath {
  param(
    [string]$ConfiguredPath,
    [string]$CommandName
  )

  if ($ConfiguredPath -and (Test-Path -LiteralPath $ConfiguredPath)) {
    return $ConfiguredPath
  }

  $command = Get-Command $CommandName -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Path
  }

  return $null
}

$config = $null
if ($ConfigPath) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[FAIL] Config - Missing config at $ConfigPath"
    exit 1
  }

  $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
}

Write-Host "MAGI Doctor Report"
Write-Host "------------------"
Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
Write-Host ("OS: {0}" -f $PSVersionTable.OS)
Write-Host ("TEMP: {0}" -f $env:TEMP)
Write-Host ("TMP: {0}" -f $env:TMP)

$freeC = Get-FreeSpaceGB -DriveName "C"
$freeF = Get-FreeSpaceGB -DriveName "F"

if ($null -ne $freeC) {
  Write-Host ("Free space C: {0} GB" -f $freeC)
} else {
  Write-Host "Free space C: (drive not found)"
}

if ($null -ne $freeF) {
  Write-Host ("Free space F: {0} GB" -f $freeF)
} else {
  Write-Host "Free space F: (drive not found)"
}

$allPassed = $true
$tempExpected = "F:\\MAGI\\temp"
$tempPass = ($env:TEMP -eq $tempExpected -and $env:TMP -eq $tempExpected)
$allPassed = $allPassed -and (Write-CheckResult -Name "TEMP/TMP location" -Passed $tempPass -Message (if ($tempPass) { "Using $tempExpected" } else { "TEMP/TMP not set to $tempExpected" }) -Hint "Set TEMP/TMP to F:\\MAGI\\temp (run scripts/run_nightly.ps1 or set env vars manually).")

$driveFPass = $null -ne $freeF
$allPassed = $allPassed -and (Write-CheckResult -Name "F: drive" -Passed $driveFPass -Message (if ($driveFPass) { "Detected with $freeF GB free" } else { "F: drive not detected" }) -Hint "Connect the external SSD and ensure it mounts as F:.")

$ffmpegPath = Resolve-ConfiguredPath -ConfiguredPath $null -CommandName "ffmpeg"
$ffmpegPass = $false
if ($ffmpegPath) {
  & $ffmpegPath -version | Out-Null
  $ffmpegPass = $LASTEXITCODE -eq 0
}

$allPassed = $allPassed -and (Write-CheckResult -Name "ffmpeg" -Passed $ffmpegPass -Message (if ($ffmpegPass) { "Found at $ffmpegPath" } else { "ffmpeg not found" }) -Hint "Install with: winget install Gyan.FFmpeg")

$whisperConfigured = $null
if ($config -and $config.transcription -and $config.transcription.whisperCpp) {
  $whisperConfigured = $config.transcription.whisperCpp.binaryPath
}

$whisperPath = Resolve-ConfiguredPath -ConfiguredPath $whisperConfigured -CommandName "whisper-cli"
if (-not $whisperPath) {
  $whisperPath = Resolve-ConfiguredPath -ConfiguredPath $whisperConfigured -CommandName "main"
}

$whisperPass = $false
if ($whisperPath) {
  $whisperPass = $true
}

$fasterWhisperConfigured = $null
if ($config -and $config.transcription -and $config.transcription.fasterWhisper) {
  $fasterWhisperConfigured = $config.transcription.fasterWhisper.binaryPath
}

$fasterWhisperPath = Resolve-ConfiguredPath -ConfiguredPath $fasterWhisperConfigured -CommandName "faster-whisper"
$pythonPath = Resolve-ConfiguredPath -ConfiguredPath $null -CommandName "python"
$fasterWhisperModulePass = $false
if (-not $fasterWhisperPath -and $pythonPath) {
  & $pythonPath -m pip show faster-whisper | Out-Null
  $fasterWhisperModulePass = $LASTEXITCODE -eq 0
}

$fasterWhisperPass = $false
if ($fasterWhisperPath -or $fasterWhisperModulePass) {
  $fasterWhisperPass = $true
}

$backendPass = $whisperPass -or $fasterWhisperPass

$backendMessage = if ($backendPass) {
  if ($whisperPass) {
    "whisper.cpp available at $whisperPath"
  } else {
    "faster-whisper available"
  }
} else {
  "No whisper backend found"
}

$backendHint = "Install whisper.cpp (preferred) from https://github.com/ggerganov/whisper.cpp or run: pip install faster-whisper"
$allPassed = $allPassed -and (Write-CheckResult -Name "whisper backend" -Passed $backendPass -Message $backendMessage -Hint $backendHint)

if ($whisperPass -and $config -and $config.transcription -and $config.transcription.whisperCpp) {
  $modelPath = $config.transcription.whisperCpp.modelPath
  $modelPass = $modelPath -and (Test-Path -LiteralPath $modelPath)
  $allPassed = $allPassed -and (Write-CheckResult -Name "whisper.cpp model" -Passed $modelPass -Message (if ($modelPass) { "Found model at $modelPath" } else { "Model path not set or missing" }) -Hint "Set transcription.whisperCpp.modelPath in configs/pipeline-settings.json to a valid ggml model file.")
}

if (-not $fasterWhisperPath -and -not $fasterWhisperModulePass) {
  $pythonPass = $false
  if ($pythonPath) {
    $pythonPass = $true
  }
  $allPassed = $allPassed -and (Write-CheckResult -Name "python (for faster-whisper)" -Passed $pythonPass -Message (if ($pythonPass) { "Found at $pythonPath" } else { "python not found" }) -Hint "Install Python from https://www.python.org/downloads/ or via winget install Python.Python.3")
}

if (-not $allPassed) {
  Write-Host "\nOne or more checks failed. Resolve the failures above before running the nightly pipeline."
  exit 1
}

Write-Host "\nAll checks passed."
