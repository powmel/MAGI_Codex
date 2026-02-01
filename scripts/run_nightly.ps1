Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")

Import-Module (Join-Path $repoRoot "src" "MagiPipeline.psm1")

$configPath = Join-Path $repoRoot "configs" "pipeline-settings.json"
if (-not (Test-Path -LiteralPath $configPath)) {
  throw "Missing config: $configPath"
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
$dataRoot = $config.dataRoot
$forcedTempRoot = "F:\\MAGI\\temp"
$tempRoot = $forcedTempRoot
$logRoot = $config.logRoot

$env:TEMP = $tempRoot
$env:TMP = $tempRoot

Ensure-MagiDirectory -Path $dataRoot
Ensure-MagiDirectory -Path $tempRoot
Ensure-MagiDirectory -Path $logRoot

$logFile = Join-Path $logRoot ("run_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$log = New-MagiLogWriter -LogFile $logFile

$log.Invoke("MAGI nightly run started")
$log.Invoke("TEMP set to $env:TEMP")
$log.Invoke("TMP set to $env:TMP")

$doctorPath = Join-Path $scriptRoot "doctor.ps1"
if (-not (Test-Path -LiteralPath $doctorPath)) {
  throw "Missing dependency checker: $doctorPath"
}

& $doctorPath -ConfigPath $configPath
if ($LASTEXITCODE -ne 0) {
  throw "Dependency checks failed. Run scripts/doctor.ps1 for details."
}

$ffmpegPath = Get-MagiFfmpegPath

$inboxDir = Join-Path $dataRoot "inbox_wav"
$archiveDir = Join-Path $dataRoot "archive_audio"
$chunkRoot = Join-Path $dataRoot "chunks"
$extractedDir = Join-Path $dataRoot "extracted"
$dailyDir = Join-Path $dataRoot "daily"

Ensure-MagiDirectory -Path $inboxDir
Ensure-MagiDirectory -Path $archiveDir
Ensure-MagiDirectory -Path $chunkRoot
Ensure-MagiDirectory -Path $extractedDir
Ensure-MagiDirectory -Path $dailyDir

$chunkDirs = @()
$tempFiles = @()

try {
  $audioFiles = Get-ChildItem -LiteralPath $inboxDir -Filter "*.wav" -File -ErrorAction SilentlyContinue
  if (-not $audioFiles) {
    $log.Invoke("No audio files found in inbox_wav")
    return
  }

  foreach ($audioFile in $audioFiles) {
    $sessionId = "{0}_{1}" -f $audioFile.BaseName, (Get-Date -Format "yyyyMMdd_HHmmss")
    $log.Invoke("Processing $($audioFile.Name) as $sessionId")

    if ($config.archive.enabled -eq $true) {
      $archiveExt = if ($config.archive.codec -eq "flac") { "flac" } else { "opus" }
      $archiveName = "{0}.{1}" -f $audioFile.BaseName, $archiveExt
      $archivePath = Join-Path $archiveDir $archiveName
      Convert-MagiAudioToArchive -InputFile $audioFile.FullName -OutputFile $archivePath -Codec $config.archive.codec -Bitrate $config.archive.bitrate
      $log.Invoke("Archived audio to $archivePath")
    }

    $chunkDir = Join-Path $chunkRoot $sessionId
    $chunkDirs += $chunkDir

    $chunks = Convert-MagiAudioToChunks -InputFile $audioFile.FullName -OutputDir $chunkDir -SegmentSeconds $config.chunking.segmentSeconds
    $log.Invoke("Created $($chunks.Count) chunks")

    $pass1Segments = @()
    $pass2Segments = @()

    foreach ($chunk in $chunks) {
      $chunkIndex = [int]([regex]::Match($chunk.BaseName, "\d+$").Value)
      $chunkOffset = $chunkIndex * $config.chunking.segmentSeconds
      $chunkId = $chunk.BaseName
      $transcriptDir = Join-Path $tempRoot "transcripts"

      $pass1Segments += Invoke-MagiTranscription -AudioPath $chunk.FullName -OutputDir $transcriptDir -ChunkId $chunkId -ChunkOffsetSeconds $chunkOffset -PreferredTool $config.transcription.preferred -Config $config.transcription -PassLabel "pass1"
    }

    $candidates = Find-MagiCandidates -Segments $pass1Segments -DetectionConfig $config.detection
    $log.Invoke("Candidate segments: $($candidates.Count)")

    foreach ($candidate in $candidates) {
      $chunkFile = Join-Path $chunkDir ("{0}.wav" -f $candidate.chunkId)
      if (-not (Test-Path -LiteralPath $chunkFile)) {
        continue
      }

      $snippetName = "{0}_{1}_{2}.wav" -f $candidate.chunkId, ($candidate.startSeconds.ToString("0.###")), ($candidate.endSeconds.ToString("0.###"))
      $snippetPath = Join-Path $tempRoot $snippetName
      $tempFiles += $snippetPath

      $startRelative = $candidate.startSeconds - ([int]([regex]::Match($candidate.chunkId, "\d+$").Value) * $config.chunking.segmentSeconds)
      $duration = $candidate.endSeconds - $candidate.startSeconds

      & $ffmpegPath -hide_banner -y -i $chunkFile -ss $startRelative -t $duration $snippetPath | Out-Null

      $pass2Segments += Invoke-MagiTranscription -AudioPath $snippetPath -OutputDir (Join-Path $tempRoot "transcripts") -ChunkId $candidate.chunkId -ChunkOffsetSeconds $candidate.startSeconds -PreferredTool $config.transcription.preferred -Config ([pscustomobject]@{
          whisperCpp = [pscustomobject]@{
            binaryPath = $config.transcription.whisperCpp.binaryPath
            modelPath = if ($config.transcription.pass2.modelPath) { $config.transcription.pass2.modelPath } else { $config.transcription.whisperCpp.modelPath }
            threads = $config.transcription.pass2.threads
            language = $config.transcription.whisperCpp.language
          }
          fasterWhisper = [pscustomobject]@{
            binaryPath = $config.transcription.fasterWhisper.binaryPath
            model = if ($config.transcription.pass2.model) { $config.transcription.pass2.model } else { $config.transcription.fasterWhisper.model }
            device = $config.transcription.fasterWhisper.device
            computeType = $config.transcription.fasterWhisper.computeType
          }
        }) -PassLabel "pass2"
    }

    $mergedSegments = Merge-MagiSegments -Pass1Segments $pass1Segments -Pass2Segments $pass2Segments
    $extracted = Get-MagiExtractedItems -Segments $mergedSegments -DetectionConfig $config.detection

    $payload = [ordered]@{
      source = [ordered]@{
        file = $audioFile.Name
        sessionId = $sessionId
        processedAt = (Get-Date).ToString("o")
      }
      transcript = [ordered]@{
        segmentCount = $mergedSegments.Count
        pass2OverrideCount = $pass2Segments.Count
      }
      events = $extracted.events
      tasks = $extracted.tasks
      schedule = $extracted.schedule
    }

    $extractedPath = Join-Path $extractedDir ("{0}.json" -f $sessionId)
    Write-MagiJson -Path $extractedPath -Payload $payload

    $dailyKey = (Get-Date).ToString("yyyy-MM-dd")
    $dailyPath = Join-Path $dailyDir ("{0}.json" -f $dailyKey)

    $dailyPayload = if (Test-Path -LiteralPath $dailyPath) {
      Get-Content -Path $dailyPath -Raw | ConvertFrom-Json
    } else {
      [pscustomobject]@{
        date = $dailyKey
        events = @()
        tasks = @()
        schedule = @()
      }
    }

    $existingIds = @{
      events = @{}
      tasks = @{}
      schedule = @{}
    }

    foreach ($item in $dailyPayload.events) {
      if (-not $item.id) {
        $item.id = New-MagiStableId -Text $item.title -StartSeconds $item.evidence.windowSeconds.start -EndSeconds $item.evidence.windowSeconds.end
      }
      $existingIds.events[$item.id] = $true
    }
    foreach ($item in $dailyPayload.tasks) {
      if (-not $item.id) {
        $item.id = New-MagiStableId -Text $item.title -StartSeconds $item.evidence.windowSeconds.start -EndSeconds $item.evidence.windowSeconds.end
      }
      $existingIds.tasks[$item.id] = $true
    }
    foreach ($item in $dailyPayload.schedule) {
      if (-not $item.id) {
        $item.id = New-MagiStableId -Text $item.description -StartSeconds $item.evidence.windowSeconds.start -EndSeconds $item.evidence.windowSeconds.end
      }
      $existingIds.schedule[$item.id] = $true
    }

    foreach ($item in $extracted.events) {
      if (-not $existingIds.events.ContainsKey($item.id)) {
        $dailyPayload.events += $item
        $existingIds.events[$item.id] = $true
      }
    }
    foreach ($item in $extracted.tasks) {
      if (-not $existingIds.tasks.ContainsKey($item.id)) {
        $dailyPayload.tasks += $item
        $existingIds.tasks[$item.id] = $true
      }
    }
    foreach ($item in $extracted.schedule) {
      if (-not $existingIds.schedule.ContainsKey($item.id)) {
        $dailyPayload.schedule += $item
        $existingIds.schedule[$item.id] = $true
      }
    }

    Write-MagiJson -Path $dailyPath -Payload $dailyPayload

    $log.Invoke("Wrote extracted output to $extractedPath")
    $log.Invoke("Updated daily summary $dailyPath")
  }
}
finally {
  foreach ($tempFile in $tempFiles) {
    if (Test-Path -LiteralPath $tempFile) {
      Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
  }

  foreach ($chunkDir in $chunkDirs) {
    if (Test-Path -LiteralPath $chunkDir) {
      Remove-Item -LiteralPath $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  $log.Invoke("Cleanup completed")
}
