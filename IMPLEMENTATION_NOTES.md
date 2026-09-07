# Kura workspace upgrade

For the latest cross-Mac status and next steps, read [HANDOFF.md](HANDOFF.md).
The verification entries below are chronological; later entries supersede older ones.

## Implemented

- Prepare / conversation / wrap-up workspace with readable typography, attachment chips, explicit status and errors, visible Send / Stop, a menu-bar entry, compact mode, and remembered placement.
- Coalesced autosave, atomic local writes, recovery of active sessions, full transcript retention, old-format decoding, archive save on wrap-up/new session, recoverable meeting deletion, and quit-time saving.
- Typed and saved-meeting questions use the correct transcript and attachments. Busy sends preserve input. Auto answers require the toggle and finalized remote speech. Request identities guard stale streaming callbacks.
- Full-session wrap-up processing in bounded sections; editable summaries, decisions, tasks, owners, deadlines, completion state, valid source links, and copyable follow-up drafts. Regeneration preserves existing tasks and decisions.
- Multi-file drag/drop, pasted notes, extraction status, attachment preview/removal, explicit import/context limits, meeting templates/goals, and reusable context packs.
- Search, rename, favorites, tags, selected-meeting exports and Q&A, speaker/text corrections, timestamps, and passage copy actions.
- Settings is organized into AI setup, Audio, Appearance, and Shortcuts. Each provider has isolated Keychain save/show/hide/paste/remove controls, unsaved-state feedback, confirmation before removal, and verified save feedback. Answer-provider connection tests use a tiny explicit request and support cancellation; configuration changes invalidate previous test feedback. Restart waits for session saving.
- Optional continuous microphone capture as You. Free local whisper.cpp transcription plus pyannote Community-1 speaker separation, with explicit installation/path setup. Deepgram code and controls removed. Optional local meeting-window OCR suggests names only from explicit speaking cues or matching visible caption text; names require confirmation.
- Dedicated Anthropic and OpenAI BYO-key providers, searchable account model discovery (including Anthropic pagination), manual model IDs, Claude capability-driven effort choices, OpenAI Responses streaming, provider-default omission, and configurable reasoning/output token caps. OpenAI does not report per-model effort compatibility in its model list; the UI explicitly warns that listed effort values are API options, not universal model support.
- Batched AI text updates, plain text during streaming then Markdown on completion, unchanged-row equality, bounded visible transcript pages with earlier-page loading, and follow-at-bottom scrolling. Removed the unused background screenshot theme sampler; Auto now follows macOS. The removed source remains recoverable in Git.

## Verification

The current preview UI pass exercised Listen → simulated partial/final transcript → automatic answer → Pause, local backend selection and missing-path validation, and both Claude/OpenAI model refresh screens. Claude model selection exposed only fixture-supported efforts. These are simulated UI checks, not real model/API inference. This pass discovered a synchronous Keychain read blocking the app during provider navigation; credential reads/writes now run off the UI thread, and preview credentials are memory-only.

Run `swift build -c release` and `bash check.sh`. The regression runner uses temporary folders and fake AI providers; it makes no external AI calls.

The regression suite now includes 24 Swift checks and 4 Python checks. They cover the local worker protocol, WAV encoding, final-window drain through Q&A, partial-versus-final Q&A triggering, speaker overlap matching, word alignment, model capability parsing, and provider reasoning payloads. Worker integration tests use a stub, not installed ML models. Packaging produces `Kura Updated.app`: the pre-existing root-owned `Kura.app` remains untouched. Rebuild using `swift build -c release` followed by `KURA_APP_OUTPUT="Kura Updated.app" bash bundle.sh`.

The separate `.build/KuraPreview.app` uses synthetic meetings, isolated credentials, and a fake streaming provider. Computer-use visual QA covered conversation, context editor, attachment preview, wrap-up, speaker editor, saved history, new-meeting preparation, capture setup, and all four Settings categories. UI actions checked include saving a context pack, task completion, source navigation, speaker correction, history selection, new meeting, planning template, attachment preview/Done, window refresh (simulated), provider selection, show/hide and save/remove of a dummy key, and a simulated connection test. A cramped segmented label and a misleading new-meeting status were corrected. Some accessibility interactions crashed the external automation helper while Kura remained running; screenshot-coordinate navigation worked around this.

Automated action coverage includes send/stop/retry, busy-input preservation, auto-answer off, context file import and pack application, new-session archival, draft restoration, saved-meeting Q&A/export, speaker correction, search/favorite/delete/undo, decision capture, follow-up drafting, and wrap-up persistence. This is not a claim of exhaustive end-to-end coverage: real credential success/failure, native save/import dialogs, permissions, global hotkeys, audio hardware, observation start/stop, and every menu/control combination still need a real-device acceptance pass.

## Remaining validation / limits

- The Settings Restart action was exercised in the preview: a replacement preview launched and the previous process exited. Ollama setup was visually checked with simulated model detection. The built app is ad-hoc signed; macOS may ask for permissions again after a rebuild.

- Real Zoom/Meet/Teams calls, microphone permissions, audio-device changes, and actual local-model inference must be exercised on the user’s setup. No real meeting content or audio was submitted during development. whisper-cli was not installed on PATH and the system Python was 3.9; the local option requires the dedicated environment and models described in the setup guide.
- Community-1 requires the user to accept Hugging Face model-access conditions and download the complete local weights. No acceptance or credentials were supplied on the user’s behalf. Apple transcription alone does not diarize. Local labels use overlapping windows, not enrolled voice identities; long absences and reconnecting can start new labels. This is delayed rolling-window transcription, not zero-latency diarization.
- Local audio temporary folders are private to the user and removed on normal completion/error. A crash may leave temporary audio behind. Inference backlog is bounded; a slow worker stops with an error. Final draining can wait up to 120 seconds. No universal real-time performance claim is made.
- Window observation is OCR, not a platform participant API. Names are tentative and may be unavailable when captions/cues are hidden. Overlap cannot be reliably named from a gallery border.
- Apple speech uses on-device recognition when supported and may otherwise use Apple’s service. This is not an unconditional offline-transcription claim.
- Long-meeting summary sections preserve coverage, but model extraction can still miss or misinterpret facts; all wrap-up fields remain editable. Follow-up drafts are never automatically sent.
- Imports and background context have disclosed character limits. Image-only PDFs need text extraction outside Kura.

## API references

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- [Community-1 local setup and license](https://huggingface.co/pyannote/speaker-diarization-community-1)
- [OpenAI Models API](https://developers.openai.com/api/reference/resources/models/methods/list)
- [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning)
- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Claude model discovery](https://platform.claude.com/docs/en/api/models/list)
- [Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Apple ScreenCaptureKit screenshots](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
# September 7 follow-up: pickers, branding, and capture diagnostics

## Audio continuity follow-up

### Diagnostic build and Cloak comparison

Settings → Audio now includes a thread-safe live diagnostic snapshot: capture
stage, processed/rejected buffers, peak RMS level, recognition result count, and
last error domain/code. No transcript text, audio, or credentials are recorded
in that report. It remains readable when the serial audio queue is blocked in a
native call. Listen now reports a pending shutdown instead of silently ignoring
the click. Delayed speech-recognition restarts are guarded against stale sessions.

An explicit Audio capture picker retains the direct callback as the default and
offers `Cloak compatibility · original capture` for A/B testing. The compatibility
path restores the upstream AVAudioEngine/device assignment sequence while retaining
owned buffer copies and separate capture/recognition lifecycle protection. It is
not automatically selected and is not claimed to fix the earlier native-input
stall. Pause before switching methods. Both feed the same selected transcription
backend and the same workspace. Real-device testing of both is still required.

The upstream reference was Cloak commit
`260055d3c9d51b4812b27a6142843244d7f10fb6`. UI control remains blocked by the
desktop tool's native-pipe startup failure; no real audio acceptance was claimed.

The direct audio callback incorrectly compared its lifetime token against the
speech-recognition generation. A final result, recognition error, or scheduled
55-second rotation advanced that generation and caused all remaining hardware
buffers to be discarded. Capture and recognition now have independent lifecycle
tokens. Stopping capture invalidates both; restarting recognition invalidates
only recognition callbacks. A regression check covers repeated rotations and
stop/restart invalidation. All 25 Swift and 4 Python checks pass.

This is a confirmed code defect and regression-tested fix, not proof of a live
audio-to-provider success. Desktop control failed with `Sky Computer Use native
pipe startup failed`, including after resetting its JavaScript kernel, so real
capture, permission prompts, and end-to-end Q&A could not be verified in this run.

- Settings and the workspace now share always-visible model and reasoning controls. Model rows and effort choices explicitly dismiss their popovers; manual entry remains available. UI dismissal verified in the isolated preview.
- The bundled Kura icon now appears beside the sidebar name and in the header when the sidebar is hidden, plus Settings.
- Settings has a live-refreshing Permissions tab with individual request/settings actions. System-audio process-tap permission is explicitly unverified rather than inferred from screen or microphone access.
- Real playback investigation found the previous app blocked inside AVAudioEngine.inputNode/HAL initialization (sample `/tmp/Kura_2026-09-07_133313_Wedo.sample.txt`). The capture implementation now uses a direct AudioDevice IO callback. A subsequent live run still blocked in Core Audio registration (`/tmp/kura-audio-direct-sample.txt`); this is not a verified complete audio fix.
- The rebuilt app reports no Speech Recognition grant. Apple Listen now checks that grant before entering Core Audio setup and directs users to grant it. A no-audible-audio warning appears after 12 seconds.
- 24 Swift and 4 Python regression checks passed after the direct callback change. These include simulated transcript-to-Q&A, not a successful real microphone/system-audio/ML end-to-end test. The user's production Settings previously displayed a successful OpenAI connection, but a real transcript-backed OpenAI answer remains unverified.

## Conversational turn timing — September 7, 2026, 16:55

Later real-app checks supersede the earlier UI-blocked notes: installed build
20260907161221 captured system playback through Cloak compatibility plus Apple
recognition. Manual synthetic OpenAI Q&A returned the expected Friday/Alex/Thursday
answer. A spoken arithmetic test returned `2 + 2 = 4.` automatically, but the
saved speech-to-request timestamps showed a 48.86-second wait before sending.

Build 20260907164801 adds monotonic short-pause endpointing: 1.2 seconds of
unchanged text plus 0.9 seconds below 0.003 RMS, checked every 200 ms while audio
buffers are still arriving. It commits the turn and rotates recognition, not
hardware capture. The 55-second fallback remains for continuous/noisy audio.
Auto-answer delay is now 250 ms, question detection is broader, deduplication is
per transcript-line identity (not lifetime text), and the latest question can
wait up to 15 seconds for an active response, with visible queued status.
This remains heuristic endpointing, not semantic/VAD turn detection; local
Whisper chunk latency is unchanged.

31 Swift and 4 Python checks passed; release build, signed bundle verification,
and installer packaging passed. Installed at `/Applications/Kura.app`; previous
app preserved at `.build/app-backups/conversation-Jhtv4s/Kura.app`.
The NEW build's real latency is NOT yet verified: rebuilding invalidated grants,
Speech Recognition was reauthorized, but compatibility capture remained at
Connecting audio with no input. Testing was paused. `codesign -dvv` confirms
Signature=adhoc and no TeamIdentifier; `security find-identity -v -p codesigning`
reports zero valid identities. Do not repeatedly rebuild/reinstall and ask for
the same grants. Establish a stable signing identity before further replacements.
No signing certificate was created, no TCC reset/database edit was performed,
and no stored API key was exposed.
