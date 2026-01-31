# MAGI Audio Log Pipeline (Windows-first)

This repository provides a Windows-first nightly pipeline for processing MAGI audio logs using local speech-to-text tools and producing structured JSON outputs (events, tasks, schedule) with evidence metadata.

## Repository structure

```
configs/   # Pipeline settings + JSON schemas
docs/      # Project documentation + examples
scripts/   # Entry-point PowerShell scripts
src/       # PowerShell module implementation
```

## How to run locally on Windows

### 1) Install ffmpeg

Install via winget (recommended):

```powershell
winget install Gyan.FFmpeg
```

Then confirm `ffmpeg` is on your PATH:

```powershell
ffmpeg -version
```

### 2) Install whisper.cpp (preferred) or faster-whisper

#### Option A: whisper.cpp (preferred)

1. Download or build `whisper.cpp` from <https://github.com/ggerganov/whisper.cpp>.
2. Place the `main.exe` binary somewhere stable (e.g., `F:\MAGI\tools\whisper.cpp\main.exe`).
3. Download a model file (e.g., `ggml-base.en.bin`) and store it locally (e.g., `F:\MAGI\tools\whisper.cpp\models\ggml-base.en.bin`).
4. Update `configs/pipeline-settings.json`:

```json
"whisperCpp": {
  "binaryPath": "F:\\MAGI\\tools\\whisper.cpp\\main.exe",
  "modelPath": "F:\\MAGI\\tools\\whisper.cpp\\models\\ggml-base.en.bin",
  "threads": 4,
  "language": "en"
}
```

#### Option B: faster-whisper

1. Install Python and pip if you don't already have them.
2. Install faster-whisper:

```powershell
pip install faster-whisper
```

3. Ensure the `faster-whisper` CLI is on PATH, or set `transcription.fasterWhisper.binaryPath` in `configs/pipeline-settings.json`.

### 3) Configure data paths

All runtime data must live under the external SSD:

- `F:\MAGI\data`
- `F:\MAGI\temp`
- `F:\MAGI\logs`

These are already defaulted in `configs/pipeline-settings.json`.

### 4) Drop WAV files for processing

Place WAV files in:

```
F:\MAGI\data\inbox_wav
```

### 5) Run the nightly pipeline

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_nightly.ps1
```


## Quick start (no IDE)

```powershell
git clone <repo-url> F:\MAGI\code\repo
Set-Location F:\MAGI\code\repo
powershell -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -ConfigPath .\configs\pipeline-settings.json
powershell -ExecutionPolicy Bypass -File .\scripts\run_nightly.ps1
```

## Outputs and verification

After a successful run, you will find:

- Granular extracts: `F:\MAGI\data\extracted\*.json`
- Daily summary: `F:\MAGI\data\daily\YYYY-MM-DD.json`
- Logs: `F:\MAGI\logs\run_*.log`

Use the JSON schemas to validate outputs:

- `configs/extracted.schema.json`
- `configs/daily.schema.json`

Example outputs are available under `docs/examples/`.

## Notes

- The pipeline automatically cleans up chunked audio files and temp files after each run.
- Output logs avoid raw transcript content. Evidence snippets are stored only in the JSON outputs.
- No audio data is committed to the repo; data remains in `F:\MAGI\data`.


## Troubleshooting (minimal)

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Dependency checks failed` | Missing ffmpeg or STT backend | Run `.\scripts\doctor.ps1` and follow install hints |
| `ffmpeg not found` | ffmpeg not installed or missing PATH | `winget install Gyan.FFmpeg` |
| `No whisper backend found` | whisper.cpp/faster-whisper not installed | Install whisper.cpp or run `pip install faster-whisper` |

