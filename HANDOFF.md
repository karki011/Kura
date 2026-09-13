# Kura handoff — September 12, 2026 (pm update)

Supersedes the Sept 8 notes below where they conflict. Work is still on `kura-launch`; new work is uncommitted on top of `f7aa06f` at the time of writing. 41 Swift regression checks + 4 Python tests green (`bash check.sh`).

## Done September 12 (live-tested on this Mac)

1. **Conversation-order fix**: on-device utterances commit on a separate channel from partials; the open partial was never closed, so live text kept rewriting a stale mid-transcript bubble. `TranscriptStore.discardOpenSpeechPartials()` now drops it as each utterance commits (`OverlayViewModel.swift` onSpeakerTranscript). Verified live with `Tests/Fixtures/two_speaker_conversation.sh` (two-voice TTS playback through the system-audio tap).
2. **Diarizer default for real use**: LS-EEND merges even clearly different voices; Sortformer separated the test speakers correctly. Settings now on Sortformer (`defaults: diarizerBackend=sortformer`).
3. **Deep work model split** (Settings → AI setup → "Deep work model"): live auto answers keep the fast model/effort; wrap-ups, Catch me up, and typed questions can use a separate model + effort (blank model = same model, higher effort). Deep requests get a 30s first-token window. Keys: `deepModelEnabled`, `deep<Provider>Model/Effort`.
4. **Custom vocabulary rescoring** (Settings → Audio, fluid engine only): terms in `customVocabulary` (one per line) are rescored against committed utterances via FluidAudio's CTC spotter (`VocabularyBoostingSession`). Lazy — the ~110MB CTC model downloads only when terms exist. Partials stay raw; corrections land at commit.
5. **OpenAI Realtime engine — built and live-tested**: third "Listen with" option (`transcriptionBackend=realtime`), `Sources/Kura/RealtimeSpeechEngine.swift`. GA WebSocket interface (no beta header), `gpt-realtime-mini`, pcm16/24kHz, `semantic_vad` with `create_response: false`; committed lines come from `input_audio_transcription.completed`, auto-answers from `response.create` with `response.output_text.delta` (GA renamed beta's `response.text.delta`). 55-min rotation with context handoff; one reconnect on drop. Uses the Keychain `openai-direct` key regardless of answer provider. Live test: clean punctuated transcript (noticeably better than Parakeet) and auto-answer through the realtime session. Anti-hallucination guardrails verified live (declines instead of inventing facts). No speaker labels on this engine; ~$0.36/hr.
6. **Context-per-meeting audit**: verified no leak (storage + live switching + archive flow all per-meeting). UX hardening: sidebar clicks during transitions now show a notice instead of silently dropping; the context window is titled "Meeting Context" (was "Session Context").
7. **Per-answer cost + latency tracking**: every provider stream now reports token usage (`LLMUsage`, onUsage channel on the `LLMProvider` protocol; `response.completed` for OpenAI Responses, message_start/message_delta for Anthropic, include_usage for chat-completions, eval counts for Ollama, `response.done` for Realtime). `ModelPricing.swift` prefix-match price table (sources + date in file comment; estimates, not invoice-grade). Each Kura answer line shows a caption (`gpt-5.5 · 158 in · 28 out · $0.0016 · first token 2.4s · 2.5s` — toggle in Settings → AI setup → "Cost & timing"); the status bar shows the meeting's running `AI spend` total, persisted as `Meeting.aiSpendUSD`. Live-verified: typed question priced correctly ($0.0016 on gpt-5.5).
8. **Delete-meeting UX**: deleting the meeting on screen now archives the live session and lands on a fresh empty meeting instead of dropping back into the live session's old chat (which read as "the delete didn't work"). Live-verified.
9. **Speech gauntlet E2E** (`Tests/Fixtures/speech_gauntlet.sh` — 3 voices, fast/slow/monologue/rapid exchange, planted questions): conversation order held, no stale-partial regression; both planted questions auto-answered with grounded, guardrailed answers + cost captions; auto-title and spend total worked. Weaknesses found: tight gaps (≤1.5s between turns) merge multiple turns into one line — the EOU debounce (1.28s) plus TTS startup latency leaves too little silence; one very fast sentence (-r 250) was dropped entirely by the ASR; speaker attribution is unreliable on merged turns (3 voices through one loudspeaker is the hard case — real meetings with separate mics should do better, unverified).
10. **Wrap-up is now a document, not form fields** (`WrapUpView`): the structured boxes (Summary/Decisions/task rows with owner+deadline inputs/Open questions/Follow-up) are gone. The wrap-up lives in `wrapUp.notes` (freeform markdown) and renders as a clean structured document via MarkdownText; an "Edit" chip toggles a raw text editor. Generate streams markdown from the deep provider, revising one coherent document across transcript chunks. Legacy meetings seed their structured fields into notes once (never overwriting edits); export prefers notes, falls back to legacy rendering. `WrapUpGenerator`'s JSON extraction path was removed. Docs (README/IMPLEMENTATION_NOTES/MARKETING) still describe the old structured UI — needs a docs pass.
11. **Button theming pass**: `KuraChipButtonStyle(tinted:)` — tinted (teal) is reserved for primary actions (Generate, assist chips); secondary actions (Back to live, Add context, Undo, Export…) are neutral chips. The More menu is now a chromeless vertical ellipsis (rotated SF Symbol, no card bezel), menu verified working.
12. **Wrap-up footer redesign**: Export moved to the top row (Edit · Export… · Generate); Favorite is now a star toggle (orange when on, mirrors the library star instantly); Tags is a compact capsule field with a tag icon. The footer is pinned OUTSIDE the document ScrollView — inside it, a long document clipped the row out of reach.
13. **Wrap-up loading state**: determinate progress (`wrapUpFraction`, per transcript chunk) drives a status card — sparkles icon + "Reviewing section X of Y…" + accent progress bar in a tinted card; a pulsing accent caret marks where streaming text lands (replaces the stray mid-document spinner). Verified live on a synthetic 3-chunk meeting (23k chars): fraction steps 0→…→1, card present in the AX tree mid-run; screenshots lag the 1-6s window, so visual confirmation was via AX.
14. **Wrap-up tab decluttered**: assist bar (Catch me up / Suggest a response / Capture decision / Wrap up) and the Answer-with row are hidden on the Wrap-up tab; the ask box stays.
15. **Engine provenance badge**: `Meeting.captureEngine` recorded at Listen start; the header shows a badge (`☁ OpenAI Realtime` in orange / `On-device` / `Apple Speech`) under the title, live and for saved meetings, with a privacy help tooltip.
16. **Realtime gauntlet** (same 3-voice varied-pace script): turn-splitting noticeably better than the EOU path (monologue and planted question landed as clean single turns; only rapid 1s-gap exchanges merged); the fast 250wpm sentence was garbled but NOT dropped (EOU/Parakeet dropped it entirely); both planted questions auto-answered by the realtime model, grounded and guardrailed, first token 0.3-0.4s (vs 1.4-2.4s chat pipeline), $0.0025/$0.0049 per answer. Trash-completeness regression check added: trashed meetings never reappear after relaunch; files stay in Trash/ for Undo.

## Known limitations / honest caveats (updated)

- Realtime engine: rotation under real load and long meetings untested; utterance timestamps approximate (API reports none). Semantic VAD occasionally merges two speakers' turns into one line (no diarization by design). Realtime usage field names written from GA docs, tolerant parser, not yet diffed against a live `response.done`.
- Cost figures are estimates from a bundled price table (Fast mode/priority tier priced at standard rates); provider dashboards are the source of truth.
- Vocabulary rescoring quality untested with real speech; check a configured name in a live Listen.
- LS-EEND merged synthetic TTS voices; Sortformer separated them. Real-meeting behavior still unverified.
- AX watcher never tested against a real Zoom/Teams call. Teams: enable live captions for best cues.
- The CoreAudio tap is silent-gated; utterances commit on next audio or on Pause. EOU commit latency ~1.3s.
- `dist/Kura-1.0.0.pkg` lags source; rebuild before distributing. If `release.sh` fails moving `.build/release-app/Kura.app`, it's root-owned leftovers — `sudo chown -R subash.karki:staff .build`.

## Planned / next up (updated)

1. **Real-meeting validation loop**: Sortformer label quality, AX watcher harvesting on actual Zoom/Teams, realtime engine over a full hour (rotation), vocab rescoring accuracy.
2. **Offline re-diarization at wrap-up** (FluidAudio OfflineDiarizer, pyannote-parity clustering in 0.15.6, ~122× realtime) — needs session audio retention first (still not stored).
3. Possible: tighten the auto-answer classifier prompt if it over-fires on ambient statements.

---

# Kura handoff — September 8, 2026

Work is on branch `kura-launch`, pushed to github.com:karki011/Kura. Everything below is committed; HEAD is `e5fd1d3`. 35 Swift regression checks + 4 Python tests green (`bash check.sh`).

## Get going

```sh
git clone --branch kura-launch https://github.com/karki011/Kura.git
cd Kura && bash check.sh
```

Signed/notarized release build (credentials live on the original Mac's Keychain, not in Git):

```sh
KURA_APP_SIGNING_IDENTITY="Developer ID Application: Subash Karki (Z825V2BBX9)" \
KURA_NOTARY_PROFILE=KuraNotary bash release.sh --signed
```

`KuraNotary` is a notarytool keychain profile created from APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD/APPLE_TEAM_ID in `~/.zshrc`. `Kura.entitlements` (audio-input) is required — hardened runtime without it silently breaks mic permission.

## What the app is now

Menu-bar meeting copilot (LSUIElement, `com.karki011.kura`): captures system audio via a CoreAudio process tap, transcribes on-device, auto-answers spoken questions with BYO OpenAI/Anthropic keys, auto-titles meetings, wrap-ups, speaker labels. Three view modes: full / compact / icon (floating logo + comic speech bubble). Shadow-style step-by-step permission onboarding wizard.

## Done this session (chronological, all verified live)

1. **Signing/notarization fixed end-to-end**: Developer ID certs present; notary profile stored; pkg notarized+stapled. `Kura.entitlements` added — hardened runtime was silently blocking mic access (Kura never appeared in the Microphone pane).
2. **Answer pipeline reliability**: 5s first-token watchdog (`StreamTiming.firstDelta`) + one auto-retry; 20s idle-stall abort on the HTTP request; OpenAI Fast mode (`service_tier: priority`, default on, toggle in Settings → AI setup); default effort now `low` (provider default = medium reasoning was blowing the 5s window); watchdog window adapts to effort (5s fast / 20s deep); failed answers show the real error inline.
3. **Question detection**: `SpokenQuestion` regex (prefix + mid-sentence phrases + imperatives like "design/summarize") + LLM yes/no fallback classifier for unmatched lines (once per line, 5s watchdog). Newer spoken question interrupts a stale streaming auto-answer; typed answers never interrupted (30s queue).
4. **Transcript integrity**: `IncrementalTranscriptCommitter` — commits the stable head of Apple's cumulative partials at sentence boundaries so continuous speech can't be revised away. EOU-latching fix (every utterance commits, not just first per session).
5. **On-device speaker labels (FluidAudio v0.15.6, SPM)**: Settings → Audio → "Listen with: Apple Speech (default) / On-device · speaker labels". Parakeet EOU streaming ASR + diarizer picker: LS-EEND (default, up to 10 speakers) / Sortformer (most stable, max 4). Models auto-download to `~/Library/Application Support/FluidAudio/Models`. Python whisper/pyannote worker retired from the capture path (files kept — two tests use them).
6. **Speaker identity without a bot**: `MeetingAppWatcher` reads the chosen meeting APP's AX tree every 1s (reuses Accessibility permission; screenshot OCR kept as fallback). `SpeakerBindingTracker`: same screen-cue name matching the same voice slot twice → auto-names the slot, "Identified NAME" + Undo. Conservative: single/conflicting cues never bind; manual renames win.
7. **UI**: teal `KuraChipButtonStyle` everywhere; icon view (chrome-less, resizable, tailed bubble, pulsing ring + level meter while listening, tap to expand); chat-style auto-scroll via `defaultScrollAnchor(.bottom)`; opacity slider actually see-through now (5–100%, base layer scales); listening timer counts from capture start; autosave no longer flickers during capture; OpenAI model catalog filters out non-chat models.
8. **Crash/freeze fixes**: failed Speech recognition tasks are now cancelled before restart (was a 1.7M-errors/min, 438% CPU meltdown); transcript rows cap rendering at 4000 chars (legacy mega-lines froze SwiftUI).

## Known limitations / honest caveats

- LS-EEND merged synthetic TTS voices in harness tests; Sortformer separated them. Real-meeting behavior unverified — if labels merge people, switch to "Most stable · max 4".
- AX watcher never tested against a real Zoom/Teams call — first real test may need harvest tuning per app. Teams: enable live captions for best cues.
- The CoreAudio tap is silent-gated: no buffers flow while the system is silent; utterances commit on next audio or on Pause.
- EOU commit latency ~1.3s after a speaker pause.
- Sortformer path caps at 4 speakers; LS-EEND at 10.
- `dist/Kura-1.0.0.pkg` lags source; rebuild before distributing. If `release.sh` fails moving `.build/release-app/Kura.app`, it's root-owned leftovers — `sudo chown -R subash.karki:staff .build`.

## Planned / next up

1. **Phase 2 — OpenAI Realtime API option** (researched, not built): third engine in "Listen with". WebSocket, PCM16/24kHz, `semantic_vad` + `turn_detection.create_response: false`, manual `response.create` with `output_modalities: ["text"]`, model `gpt-realtime-2.1-mini`. ~$0.36/hr, 60-min session cap needs rotation with context handoff. Model hears audio directly — immune to transcription garbling.
2. **Offline re-diarization at wrap-up** (Community-1 CoreML, ~122× realtime) for accurate speaker names over the whole meeting — needs session audio retention first (currently not stored).
3. **Real-meeting validation loop**: LS-EEND label quality, AX watcher harvesting on actual Zoom/Teams, auto-binding accuracy.
4. Possible: tighten the auto-answer classifier prompt if it over-fires on ambient statements.

## Testing conventions

`bash check.sh` is the gate (compiles Sources + Tests/KuraTests via swiftc — SPM modules like FluidAudio are NOT visible there; `FluidSpeechEngine.swift` is `#if canImport(FluidAudio)`-gated with a stub). Add regression checks to the list in WorkspaceTests.main. Live verification happens on the original Mac via the installed `/Applications/Kura.app` (Developer ID signed → TCC grants persist across rebuilds).
