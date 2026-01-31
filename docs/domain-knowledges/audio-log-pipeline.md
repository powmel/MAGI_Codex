# MAGI Audio Log Pipeline

## Context

MAGI processes daily audio logs on Windows via a nightly PowerShell batch. The system runs from an external SSD to avoid consuming space on `C:` and uses local speech-to-text tools to keep data private.

## Pipeline summary

1. Ingest WAV files from `F:\MAGI\data\inbox_wav`.
2. Optional archival compression to `F:\MAGI\data\archive_audio`.
3. Chunk audio into 15-minute segments under `F:\MAGI\data\chunks`.
4. Pass 1 transcription (local, fast): whisper.cpp preferred, faster-whisper fallback.
5. Candidate detection: look for schedule/task/event signals (keywords + datetime hints).
6. Pass 2 transcription: re-run only candidate windows with higher accuracy settings.
7. Merge transcripts (pass 2 overrides pass 1 for candidate windows).
8. Extract structured JSON with evidence + confidence to:
   - `F:\MAGI\data\extracted` (granular)
   - `F:\MAGI\data\daily` (daily summary)
9. Cleanup chunks and temp files reliably even on failure.

## Output structure

Each extracted JSON includes:

- `events[]`, `tasks[]`, `schedule[]`
- Evidence: chunk id, time window (seconds), and snippet
- Confidence score per item
