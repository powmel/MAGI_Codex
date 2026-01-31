# AGENTS.md — MAGI (Autonomous)

## 0. Autonomy (Non-stop execution)
- Default behavior: **execute end-to-end without asking questions**.
- Only ask for confirmation when the task involves:
  1) **Destructive changes** (mass deletion/rename, data wipe, irreversible transforms)
  2) **Security impact** (auth/permissions/secrets/exposure, dangerous commands)
  3) **Billing or external data transfer** (paid APIs, cloud billing, sending personal audio/transcripts out)
  4) **Hard-to-rollback ops** (overwrite without backup, encryption, history rewrite)

If none of the above applies, proceed autonomously and finish with a PR.

## 1. Read project docs first
Before planning or coding, read and follow:
- docs/SETUP_GUIDE.md
- docs/coding-rules/** 
- docs/development-workflows/**
- docs/domain-knowledges/**

(These docs are the source of truth for workflow and conventions.)

## 2. Target environment (Windows + External SSD)
- Runtime environment is Windows.
- C:\ is nearly full. **NEVER write outputs or temp to C:\**.
- All runtime data must live under external SSD paths:
  - DATA_ROOT = `F:\MAGI\data`
  - TEMP_ROOT = `F:\MAGI\temp`
- Repo/workspace path:
  - `F:\MAGI\code\repo` (code only)

## 3. Repo policy (privacy + performance)
- Do NOT commit any real audio files or private transcripts.
- Keep repo lightweight (scripts/config/docs). Data stays in `F:\MAGI\data`.
- Provide complete runnable files (not partial diffs), with clear README steps.

## 4. Definition of Done (for this repo)
Deliver a Windows-first audio-log pipeline that:
- Runs as a nightly batch (PowerShell entrypoint)
- Uses ffmpeg for audio conversion/chunking
- Implements **two-pass STT**:
  - Pass1: cheap/fast local transcription for all chunks
  - Candidate detection: find schedule/task/event candidates
  - Pass2: re-transcribe only candidate windows with higher accuracy settings
- Outputs structured JSON:
  - events[], tasks[], schedule[]
  - include evidence: (chunk id / timestamp window / snippet) + confidence
- Cleans up temp/chunks so disk usage stays stable
- Adds VS Code/Cursor excludes to avoid indexing audio/big files

## 5. Review guidelines
- Never log PII or raw private audio/transcript into public outputs.
- Prefer reversible changes: small commits, clear PR description, reproducible steps.
