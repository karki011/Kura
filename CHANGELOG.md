# Changelog

All notable changes to Kura are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-13

First release of Kura — a native macOS meeting copilot that lives in an
invisible overlay: it listens, transcribes, answers questions in real time,
and writes the follow-up. No Kura account, no Kura servers; bring your own
AI provider key.

### Added

- **Invisible overlay workspace** — translucent, movable panel excluded from
  screen sharing and screenshots at the OS level; light/dark/system
  appearance; full, compact, and floating-icon view modes.
- **Three transcription engines** (Settings → Audio → Listen with):
  - **Apple Speech** — zero-setup default.
  - **On-device · speaker labels** — Parakeet streaming ASR + diarization as
    CoreML models via FluidAudio; Sortformer (default, up to 4 speakers) or
    LS-EEND (up to 10); models download once, then fully offline.
  - **OpenAI Realtime** — `gpt-realtime-mini` over WebSocket with semantic
    VAD; cleanest transcripts and sub-second auto-answers (~$0.36/hr, your
    OpenAI key); 55-minute session rotation with context handoff.
- **Live auto Q&A** — spoken questions are detected (regex + LLM fallback
  classifier) and answered automatically with anti-hallucination
  guardrails; newer questions interrupt stale answers.
- **Two-model brain** — separate fast model for live answers and **deep work
  model** for wrap-ups, Catch me up, and typed questions (Settings → AI
  setup).
- **Cost & timing transparency** — every answer shows model, tokens,
  estimated cost, and latency; meetings keep a running AI-spend total in
  the status bar. Toggle in Settings → AI setup.
- **Speaker naming without a bot** — observe a Zoom/Meet/Teams window and
  Kura reads visible "Speaking:" banners and captions with Apple Vision
  (on-device) to suggest names for voice slots; confirm, correct, or undo.
- **Custom vocabulary rescoring** — on-device engine re-scores committed
  utterances against your names and jargon (CTC spotter, lazy ~110MB
  download).
- **Wrap-up document** — streaming, structured freeform-Markdown recap
  (summary, decisions, open questions, next steps) with a progress card;
  edit inline, favorite, tag, and export from the top row.
- **Meeting library** — auto-titled local sessions with search, favorites,
  tags, per-meeting context (notes, goals, PDF/text attachments), reusable
  context packs, Markdown export, and Trash with Undo.
- **Bring your own model** — Anthropic, OpenAI (Responses API with Fast
  mode), any OpenAI-compatible endpoint, or fully local Ollama; searchable
  per-key model catalog; keys in the macOS Keychain.
- **Keyboard-first** — global shortcuts for overlay, push-to-talk,
  listening, summarize, and settings (`⌃⌥Space`, hold `Right ⌥`, `⌃⌥L`,
  `⌃⌥E`, …).
- **Onboarding wizard** — step-by-step permission setup (Microphone,
  Speech Recognition, Accessibility, optional Screen Recording).
- **Distribution** — `bundle.sh` / `package.sh` / `release.sh` for signed,
  notarized app bundles and `.pkg` installers.

### Fixed (pre-release hardening)

- Turn fusion on silent-gated audio: silence watchdog feeds the transcriber
  during app-quiet gaps so end-of-utterance fires at real pauses.
- Lost speech around commits: deferred ASR epoch reset + preroll replay so
  words starting near a speaker pause are never blanked.
- Conversation order: stale live partials are discarded as utterances
  commit, so new speech never appends into old bubbles.
- Realtime answers no longer hang when the server sends an error event
  mid-stream.
- Auto Q&A toggle respected on all transcript paths; pending mic startup
  cancelled on stop; meetings persisted after summarize; oversized
  transcript lines truncated instead of emptying AI context.
- Deleting the viewed meeting archives the session and lands on a fresh
  meeting; trashed meetings stay gone after relaunch.

### Known limitations

- Realtime engine has no speaker separation (single line per turn);
  rotation past 55 minutes and hour-long meetings not yet validated.
- On-device speaker labels are session-stable but tentative; very fast
  synthetic speech can defeat cold-start ASR epochs (upstream FluidAudio
  limitation).
- Screen-cue speaker naming verified against a simulated meeting window;
  real Zoom/Teams calls still need validation.
- Cost figures are estimates from a bundled price table; provider
  dashboards are the source of truth.

[1.0.0]: https://github.com/karki011/Kura/releases/tag/v1.0.0
