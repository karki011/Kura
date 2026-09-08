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
