<p align="center">
  <img src="assets/kura_1024.png" width="160" alt="Kura icon">
</p>

<h1 align="center">Kura</h1>

<p align="center">
  <strong>Hears everything. Seen by no one.</strong><br>
  A native macOS copilot that listens to your meetings, answers questions in real time,<br>
  and writes the follow-up — from a panel only you can see.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.2%2B-000000?logo=apple&logoColor=white" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/license-MIT-0E8A6E" alt="MIT License">
  <img src="https://img.shields.io/badge/backend-none%20%C2%B7%20BYOK-555555" alt="No backend, bring your own key">
</p>

<p align="center">
  <a href="#why-kura">Why Kura</a> · <a href="#what-it-does">What it does</a> · <a href="#choose-your-ears">Transcription engines</a> · <a href="#get-started">Get started</a> · <a href="#keyboard-first">Shortcuts</a> · <a href="#responsible-use">Responsible use</a>
</p>

---

## Why Kura

In a live conversation the pressure is on *right now*. You can't pause a client call to Google something, or open a chatbot mid-interview without everyone noticing. Existing AI assistants either join the call as a visible bot, show up in your screen share, or make you look away and type.

Kura closes the gap between "I should know this" and "I do know this":

- **Invisible by design** — the overlay is excluded from screen sharing, screenshots, and recordings at the OS level. Share your screen on Zoom, Meet, or Teams and Kura never appears. No bot joins the call; nothing shows in the participant list.
- **No recording indicators while listening** — Kura taps system audio at the CoreAudio level, so no purple microphone dot lights up while it hears the room.
- **Answers in real time** — when someone asks a question, a grounded answer streams into your panel in about a second — before you've finished saying "good question."
- **Your AI, your keys** — Anthropic Claude, OpenAI, any OpenAI-compatible endpoint, or fully local Ollama. No Kura account, no subscription, no Kura servers anywhere in the loop.
- **Private by default** — on-device transcription means voices never have to leave your Mac. Meetings live in your local library, keys live in your Keychain.

> Built for prepared, transparent collaboration. Kura is not for bypassing consent, workplace rules, assessments, or interview policies. See [Responsible use](#responsible-use).

## What it does

| In the moment | After the conversation |
| --- | --- |
| **Live transcript** — a rolling, speaker-labelled record from system audio, plus optional push-to-talk for your own voice. | **Wrap-up document** — one structured, freeform Markdown recap: summary, decisions, open questions, next steps. Edit it like a doc, not a form. |
| **Auto Q&A** — detected spoken questions are answered automatically, with anti-hallucination guardrails that decline instead of inventing facts. | **Action-ready** — owner-aware to-dos and likely follow-up questions, extracted from the transcript. |
| **Ask anything** — type a question or **Catch me up** / **Suggest a response** / **Capture decision** from the assist bar. | **Meeting library** — every session auto-titled and saved locally. Search, favorite, tag, revisit, export to Markdown. |
| **Know what it costs** — every answer shows its tokens, estimated cost, and latency; the meeting keeps a running AI spend total. | **Per-meeting context** — attach notes, PDFs, and goals to *this* meeting only. Nothing silently leaks into the next one. |

### Two-model brain

Live answers need speed; wrap-ups deserve depth. Kura lets you split them: a fast model and effort for in-call answers, and a separate **deep work model** (Settings → AI setup) for wrap-ups, Catch me up, and typed questions. Same provider, your choice of models.

### Knows who's talking

On the on-device engine, Kura separates speakers locally (Sortformer by default, up to 4 voices; LS-EEND handles up to 10). Optionally, point Kura at your meeting window and it reads visible name cues — "Speaking: Alex Chen" banners, captions — with Apple Vision, entirely on-device, and suggests names for voice slots. Confirm, correct, or undo; single or conflicting cues never bind automatically. No faces are analyzed and no screenshots are stored or sent anywhere.

Add names and jargon to **custom vocabulary** (Settings → Audio) and the on-device engine rescores its transcription against them — your product names stop coming out wrong.

## Choose your ears

Three transcription engines, picked in Settings → Audio → **Listen with**:

| | **Apple Speech** (default) | **On-device · speaker labels** | **OpenAI Realtime** |
| --- | --- | --- | --- |
| Speaker separation | No (one "Unknown speaker") | Yes — Sortformer or LS-EEND | No |
| Where audio goes | On-device | On-device (offline after one-time model download) | OpenAI (your key) |
| Cost | Free | Free | ~$0.36/hr (estimate) |
| Best for | Zero-setup start | Private, labelled meetings | Cleanest live transcript + sub-second auto-answers |

The on-device engine runs Parakeet streaming ASR plus diarization as CoreML models via [FluidAudio](https://github.com/FluidInference/FluidAudio) — models download once, then work fully offline. The Realtime engine streams audio to OpenAI's Realtime API (`gpt-realtime-mini`) over WebSocket, producing noticeably cleaner punctuation and turn-splitting, with first answer tokens in a few hundred milliseconds. Every meeting records which engine captured it and shows a badge (On-device / Apple Speech / OpenAI Realtime) in the header.

[On-device speech notes](Sources/Kura/Resources/LOCAL_SPEECH_SETUP.md) have the engine details.

## A clearer meeting workflow

1. **Prepare** — name the meeting, set a goal, pick a template. Use **Add context** for notes and PDF/text attachments, or drop files onto the workspace. Context belongs to this meeting; save reusable bundles as named **context packs** and apply them explicitly.
2. **Listen** — capture system audio with **Listen** (optionally include your mic as **You** under More → Meeting capture; a headset avoids duplicated audio). Turn on **Auto answer** for spoken questions, or ask your own.
3. **Wrap up** — generate a streaming, structured recap document with a live progress card. Edit it inline, favorite the meeting, tag it, export Markdown from the top row.
4. **Revisit** — search titles, notes, tags, and transcripts. Ask questions against a saved meeting's context. Deleting moves files to a local Trash with Undo — and drops you into a fresh meeting, not a ghost of the old one.

Live sessions autosave and restore after relaunch; long wrap-ups process the full transcript in sections rather than only the last few minutes.

## Get started

### Requirements

- macOS 14.2 or later
- Xcode Command Line Tools / Swift 6.2
- An Anthropic/OpenAI-compatible API key, or [Ollama](https://ollama.com) for fully local answers

### Run from source

```bash
git clone https://github.com/karki011/Kura.git
cd Kura
swift run Kura
```

On first launch, a step-by-step wizard walks you through permissions:

- **Microphone** and **Speech Recognition** for push-to-talk input
- **Accessibility** for global shortcuts
- **Screen Recording** (optional) for observing a meeting window's name cues

Open settings with `⌃⌥,`, add a provider key, choose a model, and start a session. You can open the workspace and type without granting any audio permissions; the menu-bar icon brings Kura back whenever you need it.

### Use a local model with Ollama

1. Install and start [Ollama](https://ollama.com), then pull a model: `ollama pull llama3.2`.
2. In Kura Settings, set **Provider** to **Ollama (local)**.
3. Kura detects installed models and picks a default — no API key required.

Ollama traffic stays between Kura and the server address you configure. The OpenAI-compatible provider works for other local runtimes too, such as LM Studio.

### Connect a custom provider

Choose **Custom API (OpenAI-compatible)** in Settings, then enter a provider name, API base URL (the part before `/chat/completions`), exact model ID, and API key. Keys for Anthropic, direct OpenAI, and custom endpoints are stored separately in your macOS Keychain. The searchable model catalog lists every model your key can see, with manual entry as a fallback; you control the output/reasoning token cap and effort per model. API usage is billed by your provider — Kura supplies no credits, and shows you a per-answer estimate so there are no surprises.

### Build an app bundle

```bash
swift build -c release
./bundle.sh
open Kura.app
```

`bundle.sh` signs with an available local identity, falling back to ad-hoc. For distribution, `./package.sh` builds a notarization-ready installer; set `KURA_APP_SIGNING_IDENTITY`, `KURA_INSTALLER_SIGNING_IDENTITY`, and `KURA_NOTARY_PROFILE` for a signed, notarized release (see [RELEASING.md](RELEASING.md)).

## Keyboard-first

| Shortcut | Action |
| --- | --- |
| `⌃⌥Space` | Show or hide the overlay |
| `⌃⌥Return` | Send a question |
| Hold `Right ⌥` | Push to talk |
| `⌃⌥M` | Toggle push-to-talk listening |
| `⌃⌥L` | Toggle continuous system-audio listening |
| `⌃⌥E` | Generate and save a meeting summary |
| `⌃⌥,` | Open settings |
| `⌃⌥Q` | Quit Kura |
| `Esc` | Hide the overlay |

## Privacy, on your terms

- API keys are stored in the macOS Keychain.
- Meeting history is stored locally in your Application Support directory; exports are local files you can delete anytime.
- Apple Speech and the on-device speaker-label engine transcribe entirely on your Mac — voices never leave it. The OpenAI Realtime engine, when selected, streams meeting audio to OpenAI under your own key; the engine badge on each meeting makes that choice visible.
- Model requests go directly to the provider or local endpoint you configure. There is no Kura account, no analytics, and no hosted Kura backend in this repository.

Speech recognition, OS permissions, and model-provider data handling are governed by Apple and the provider you choose. Review those policies before using Kura with sensitive information.

## Responsible use

Use Kura only when all applicable participants, organizations, and policies allow it. Get consent where required, especially before capturing or transcribing a conversation. Do not use it to misrepresent your own work, evade recording or disclosure requirements, or gain an unfair advantage in interviews, examinations, or other evaluations.

## Project map

```text
Sources/Kura/
├── OverlayView.swift           # SwiftUI overlay and meeting library UI
├── OverlayViewModel.swift      # conversation state, assist actions, exports
├── ScreenAudioManager.swift    # system-audio tap, silence watchdog, capture flow
├── FluidSpeechEngine.swift     # on-device Parakeet ASR + diarization (FluidAudio)
├── RealtimeSpeechEngine.swift  # OpenAI Realtime API engine
├── SpeechManager.swift         # push-to-talk speech input
├── MeetingAppWatcher.swift     # meeting-window cues for speaker naming
├── LLMProvider.swift           # Anthropic, OpenAI-compatible, Ollama clients
├── ModelPricing.swift          # per-model price table for cost estimates
├── Settings.swift              # provider, model, appearance, and shortcut settings
└── MeetingStore.swift          # local meeting history, trash, context extraction
```

## Development

```bash
swift build
bash check.sh
```

`check.sh` runs the standalone Swift regression suite with Command Line Tools — no XCTest or full Xcode required. It covers persistence/migration, long transcripts, cancellation, context isolation, speaker parsing, trash completeness, and wrap-up tasks. See [implementation notes](IMPLEMENTATION_NOTES.md) for validation details and current limitations, and [HANDOFF.md](HANDOFF.md) for the latest engine work.

For a diagnostic-friendly overlay, turn on **Debug mode** in Settings and relaunch — it makes the overlay visible to screenshots so UI issues can be captured.

## Contributing

Issues and pull requests are welcome. Please keep changes macOS-native, avoid introducing telemetry or remote infrastructure, and include a short verification note with UI or audio-related changes.

## License

Kura is available under the [MIT License](LICENSE).
