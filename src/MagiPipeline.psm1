Set-StrictMode -Version Latest

function New-MagiLogWriter {
  param(
    [Parameter(Mandatory = $true)][string]$LogFile
  )

  if (-not (Test-Path -LiteralPath (Split-Path -Parent $LogFile))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogFile) -Force | Out-Null
  }

  return {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
  }
}

function Ensure-MagiDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Resolve-MagiToolPath {
  param(
    [Parameter(Mandatory = $true)][string]$ConfiguredPath,
    [Parameter(Mandatory = $true)][string]$CommandName
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

function Get-MagiFfmpegPath {
  $ffmpegPath = Resolve-MagiToolPath -ConfiguredPath "" -CommandName "ffmpeg"
  if (-not $ffmpegPath) {
    throw "ffmpeg not found. Install with: winget install Gyan.FFmpeg"
  }

  return $ffmpegPath
}

function Convert-MagiAudioToArchive {
  param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [Parameter(Mandatory = $true)][string]$Codec,
    [Parameter(Mandatory = $true)][string]$Bitrate
  )

  $ffmpegPath = Get-MagiFfmpegPath
  & $ffmpegPath -hide_banner -y -i $InputFile -c:a $Codec -b:a $Bitrate $OutputFile | Out-Null
}

function Convert-MagiAudioToChunks {
  param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [Parameter(Mandatory = $true)][int]$SegmentSeconds
  )

  Ensure-MagiDirectory -Path $OutputDir

  $chunkPattern = Join-Path $OutputDir "chunk_%03d.wav"
  $ffmpegPath = Get-MagiFfmpegPath
  & $ffmpegPath -hide_banner -y -i $InputFile -f segment -segment_time $SegmentSeconds -c copy $chunkPattern | Out-Null

  return Get-ChildItem -Path $OutputDir -Filter "chunk_*.wav" | Sort-Object Name
}

function Convert-MagiTimestampToSeconds {
  param([string]$Timestamp)

  $parts = $Timestamp -split ":"
  if ($parts.Count -lt 3) {
    return 0
  }

  $secondsParts = $parts[2] -split ","
  $hours = [int]$parts[0]
  $minutes = [int]$parts[1]
  $seconds = [int]$secondsParts[0]
  $milliseconds = if ($secondsParts.Count -gt 1) { [int]$secondsParts[1] } else { 0 }

  return ($hours * 3600) + ($minutes * 60) + $seconds + ($milliseconds / 1000)
}

function Parse-MagiSrt {
  param(
    [Parameter(Mandatory = $true)][string]$SrtPath,
    [Parameter(Mandatory = $true)][string]$ChunkId,
    [Parameter(Mandatory = $true)][double]$ChunkOffsetSeconds,
    [Parameter(Mandatory = $true)][string]$Source
  )

  $segments = @()
  $lines = Get-Content -Path $SrtPath -ErrorAction SilentlyContinue
  $currentText = @()
  $startSeconds = 0
  $endSeconds = 0

  foreach ($line in $lines) {
    if ($line -match "^\d+$") {
      continue
    }

    if ($line -match "^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$") {
      $timeParts = $line -split " --> "
      $startSeconds = Convert-MagiTimestampToSeconds -Timestamp $timeParts[0]
      $endSeconds = Convert-MagiTimestampToSeconds -Timestamp $timeParts[1]
      $currentText = @()
      continue
    }

    if ([string]::IsNullOrWhiteSpace($line)) {
      if ($currentText.Count -gt 0) {
        $text = ($currentText -join " ").Trim()
        $segments += [pscustomobject]@{
          chunkId = $ChunkId
          startSeconds = [math]::Round($ChunkOffsetSeconds + $startSeconds, 3)
          endSeconds = [math]::Round($ChunkOffsetSeconds + $endSeconds, 3)
          text = $text
          source = $Source
        }
        $currentText = @()
      }
      continue
    }

    $currentText += $line
  }

  if ($currentText.Count -gt 0) {
    $text = ($currentText -join " ").Trim()
    $segments += [pscustomobject]@{
      chunkId = $ChunkId
      startSeconds = [math]::Round($ChunkOffsetSeconds + $startSeconds, 3)
      endSeconds = [math]::Round($ChunkOffsetSeconds + $endSeconds, 3)
      text = $text
      source = $Source
    }
  }

  return $segments
}

function Invoke-MagiTranscription {
  param(
    [Parameter(Mandatory = $true)][string]$AudioPath,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [Parameter(Mandatory = $true)][string]$ChunkId,
    [Parameter(Mandatory = $true)][double]$ChunkOffsetSeconds,
    [Parameter(Mandatory = $true)][string]$PreferredTool,
    [Parameter(Mandatory = $true)][pscustomobject]$Config,
    [Parameter(Mandatory = $true)][string]$PassLabel
  )

  Ensure-MagiDirectory -Path $OutputDir
  $outputBase = Join-Path $OutputDir "${ChunkId}_${PassLabel}"
  $srtPath = "$outputBase.srt"

  if ($PreferredTool -eq "whisper.cpp") {
    $whisperPath = Resolve-MagiToolPath -ConfiguredPath $Config.whisperCpp.binaryPath -CommandName "main"
    if (-not $whisperPath) {
      throw "whisper.cpp main executable not found. Configure transcription.whisperCpp.binaryPath or add to PATH."
    }

    $modelPath = $Config.whisperCpp.modelPath
    if (-not $modelPath) {
      throw "whisper.cpp modelPath not configured."
    }

    $threads = if ($Config.whisperCpp.threads) { $Config.whisperCpp.threads } else { 4 }
    $language = if ($Config.whisperCpp.language) { $Config.whisperCpp.language } else { "en" }

    & $whisperPath -m $modelPath -f $AudioPath -osrt -of $outputBase -t $threads -l $language | Out-Null
  } else {
    $fasterPath = Resolve-MagiToolPath -ConfiguredPath $Config.fasterWhisper.binaryPath -CommandName "faster-whisper"
    if (-not $fasterPath) {
      throw "faster-whisper executable not found. Configure transcription.fasterWhisper.binaryPath or add to PATH."
    }

    $model = if ($Config.fasterWhisper.model) { $Config.fasterWhisper.model } else { "base" }
    $device = if ($Config.fasterWhisper.device) { $Config.fasterWhisper.device } else { "cpu" }
    $computeType = if ($Config.fasterWhisper.computeType) { $Config.fasterWhisper.computeType } else { "int8" }

    & $fasterPath $AudioPath --model $model --device $device --compute_type $computeType --output_dir $OutputDir --output_format srt --output_name "${ChunkId}_${PassLabel}" | Out-Null
  }

  if (-not (Test-Path -LiteralPath $srtPath)) {
    throw "Transcription failed to create SRT at $srtPath."
  }

  return Parse-MagiSrt -SrtPath $srtPath -ChunkId $ChunkId -ChunkOffsetSeconds $ChunkOffsetSeconds -Source $PassLabel
}

function Find-MagiCandidates {
  param(
    [Parameter(Mandatory = $true)][object[]]$Segments,
    [Parameter(Mandatory = $true)][pscustomobject]$DetectionConfig
  )

  $datetimePattern = "(\b\d{1,2}:\d{2}\b|\b\d{1,2}(am|pm)\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}\b)"
  $candidates = @()

  foreach ($segment in $Segments) {
    $text = $segment.text.ToLowerInvariant()
    $keywordHit = $false

    foreach ($keyword in $DetectionConfig.datetimeKeywords) {
      if ($text -like "*$keyword*") { $keywordHit = $true }
    }
    foreach ($keyword in $DetectionConfig.taskKeywords) {
      if ($text -like "*$keyword*") { $keywordHit = $true }
    }
    foreach ($keyword in $DetectionConfig.eventKeywords) {
      if ($text -like "*$keyword*") { $keywordHit = $true }
    }

    if ($text -match $datetimePattern) {
      $keywordHit = $true
    }

    if ($keywordHit) {
      $candidates += $segment
    }
  }

  return $candidates
}

function Get-MagiExtractedItems {
  param(
    [Parameter(Mandatory = $true)][object[]]$Segments,
    [Parameter(Mandatory = $true)][pscustomobject]$DetectionConfig
  )

  $items = [ordered]@{
    events = @()
    tasks = @()
    schedule = @()
  }

  $datetimePattern = "(\b\d{1,2}:\d{2}\b|\b\d{1,2}(am|pm)\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}\b|\btoday\b|\btomorrow\b|\btonight\b|\bnext week\b|\bnext month\b)"

  foreach ($segment in $Segments) {
    $text = $segment.text
    $lower = $text.ToLowerInvariant()
    $evidence = [ordered]@{
      chunkId = $segment.chunkId
      windowSeconds = [ordered]@{
        start = $segment.startSeconds
        end = $segment.endSeconds
      }
      snippet = if ($text.Length -gt 180) { $text.Substring(0, 180) + "..." } else { $text }
    }

    $confidence = if ($segment.source -eq "pass2") { 0.75 } else { 0.45 }

    $added = $false
    foreach ($keyword in $DetectionConfig.taskKeywords) {
      if ($lower -like "*$keyword*") {
        $items.tasks += [ordered]@{
          title = $text
          confidence = [math]::Round($confidence + 0.1, 2)
          evidence = $evidence
        }
        $added = $true
        break
      }
    }

    foreach ($keyword in $DetectionConfig.eventKeywords) {
      if ($lower -like "*$keyword*") {
        $items.events += [ordered]@{
          title = $text
          confidence = [math]::Round($confidence + 0.1, 2)
          evidence = $evidence
        }
        $added = $true
        break
      }
    }

    if ($lower -match $datetimePattern) {
      $items.schedule += [ordered]@{
        description = $text
        confidence = [math]::Round($confidence + 0.05, 2)
        evidence = $evidence
      }
      $added = $true
    }

    if (-not $added) {
      continue
    }
  }

  return $items
}

function Merge-MagiSegments {
  param(
    [Parameter(Mandatory = $true)][object[]]$Pass1Segments,
    [Parameter(Mandatory = $true)][object[]]$Pass2Segments
  )

  if (-not $Pass2Segments) {
    return $Pass1Segments
  }

  $merged = @()
  foreach ($segment in $Pass1Segments) {
    $overlap = $Pass2Segments | Where-Object {
      $_.chunkId -eq $segment.chunkId -and $_.startSeconds -le $segment.endSeconds -and $_.endSeconds -ge $segment.startSeconds
    }

    if ($overlap) {
      $merged += $overlap
    } else {
      $merged += $segment
    }
  }

  return $merged | Sort-Object chunkId, startSeconds, endSeconds -Unique
}

function Write-MagiJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Payload
  )

  $json = $Payload | ConvertTo-Json -Depth 8
  $json | Out-File -FilePath $Path -Encoding UTF8
}

Export-ModuleMember -Function *-Magi*
