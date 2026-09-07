<p align="center">
  <img src="assets/kura_1024.png" width="116" alt="Kura icon">
</p>

<h1 align="center">Kura</h1>

<p align="center">
  <strong>Your private AI workspace for conversations that move fast.</strong><br>
  A native macOS copilot for live context, clear next steps, and polished meeting follow-through.
</p>

<p align="center">
  <a href="#get-started">Get started</a> · <a href="#what-it-does">What it does</a> · <a href="#keyboard-first">Shortcuts</a> · <a href="#responsible-use">Responsible use</a>
</p>

---

## The calm layer in a busy conversation

Kura is a lightweight macOS overlay that helps you stay present in calls, working sessions, and customer conversations. It keeps the important context close: a live, speaker-labelled transcript, quick AI assistance, and the meeting artifacts you need once the call is over.

Bring your own Anthropic or OpenAI-compatible API key—or run a model locally with Ollama—then choose the model that fits the moment and turn a fast-moving conversation into a useful record without adding another bot to the call.

> Built for prepared, transparent collaboration. Kura is not for bypassing consent, workplace rules, assessments, or interview policies.

## What it does

| In the moment | After the conversation |
| --- | --- |
| **Live context** — captures a rolling, speaker-labelled conversation record from system audio and optional push-to-talk input. | **Structured recap** — turns the discussion into a summary, decisions, open questions, and next steps. |
| **Ask naturally** — get concise, context-aware answers or a useful suggestion for what to say next. | **Action-ready output** — extracts owner-aware to-dos and likely follow-up questions. |
| **Auto Q&A** — optionally responds when a spoken question is detected. | **Keep the thread** — save sessions locally, revisit them from the meeting library, and export clean Markdown. |
| **Bring your own model** — use Anthropic, any OpenAI-compatible endpoint, or a local Ollama model. | **Bring context in** — attach PDF or text notes to focus assistance on this session. |

### Designed to stay out of your way

- Native, movable, translucent macOS panel with light, dark, and adaptive themes
- Keyboard-first controls, including hold-to-talk
- Streaming answers with Markdown, code blocks, and checklists
- An accessory-style app experience with no call participant or meeting bot
- A capture-excluded panel configuration for privacy-conscious desktop workflows; enable Debug mode when you need the overlay visible in screenshots for diagnostics

## Get started

### Requirements

- macOS 14.2 or later
- Xcode Command Line Tools / Swift 6.2
- An Anthropic/OpenAI-compatible API key, or [Ollama](https://ollama.com) for fully local model inference

### Run from source

```bash
git clone https://github.com/karki011/Kura.git
cd Kura
swift run Kura
```

On first launch, macOS will guide you through the permissions Kura needs:

- **Microphone** and **Speech Recognition** for push-to-talk input
- **Accessibility** for global shortcuts
- **Screen Recording** is optional and only supports the adaptive overlay theme

Open settings with `⌃⌥,`, add your provider key, choose a model, and start a session.

### Use a local model with Ollama

1. Install and start [Ollama](https://ollama.com), then pull a model—for example: `ollama pull llama3.2`.
2. In Kura Settings, set **Provider** to **Ollama (local)**.
3. Keep the default server address (`http://127.0.0.1:11434`) or enter the address of your Ollama server.
4. Kura detects installed models and automatically uses one as its default. You can optionally choose another detected model in Settings. No API key is required.

Ollama traffic stays between Kura and the server address you configure. You can still use the OpenAI-compatible provider for other local runtimes that expose that API, such as LM Studio.

### Connect a custom OpenAI-compatible provider

Choose **Custom API (OpenAI-compatible)** in **Settings**, then enter a provider name (for your reference), API base URL, exact model ID, and API key. Kura stores the key in your macOS Keychain.

The base URL is the part before `/chat/completions`. For example, DeepSeek documents `https://api.deepseek.com` as its API base URL; use the current model ID from the provider's documentation. This same setup works for OpenAI itself and any provider that offers the OpenAI Chat Completions API.

### Build an app bundle

```bash
swift build -c release
./bundle.sh
open Kura.app
```

`bundle.sh` signs the app with an available local signing identity, falling back to ad-hoc signing if needed. With ad-hoc signing, macOS may ask for permissions again after each rebuild.

### Build a macOS installer

```bash
swift build -c release
./bundle.sh
./package.sh
open dist/Kura-1.0.0.pkg
```

The installer places `Kura.app` in `/Applications`, giving every user a consistent installation path. macOS still asks each user to approve Microphone, Speech Recognition, Accessibility, and optional Screen Recording access on first launch.

For public distribution, sign the app with a **Developer ID Application** certificate, sign the package with a **Developer ID Installer** certificate, and notarize it through Apple. The scripts automatically use installed Developer ID certificates. You can also set `KURA_APP_SIGNING_IDENTITY`, `KURA_INSTALLER_SIGNING_IDENTITY`, `KURA_VERSION`, `KURA_BUILD_NUMBER`, and `KURA_NOTARY_PROFILE` explicitly.

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

Kura is designed around local control:

- API keys are stored in the macOS Keychain.
- Meeting history is stored locally in your Application Support directory.
- Markdown exports are saved locally and can be deleted whenever you choose.
- Model requests go directly to the provider or local endpoint you configure—there is no Kura account or hosted Kura backend in this repository.

Speech recognition, operating-system permissions, and model-provider data handling are governed by Apple and the provider you choose. Review those settings and policies before using the app with sensitive information.

## Responsible use

Use Kura only when all applicable participants, organizations, and policies allow it. Get consent where required, especially before capturing or transcribing a conversation. Do not use it to misrepresent your own work, evade recording or disclosure requirements, or gain an unfair advantage in interviews, examinations, or other evaluations.

## Project map

```text
Sources/Kura/
├── OverlayView.swift         # SwiftUI overlay and meeting library UI
├── OverlayViewModel.swift    # conversation state, assist actions, exports
├── ScreenAudioManager.swift  # system-audio capture and transcription flow
├── SpeechManager.swift       # push-to-talk speech input
├── LLMProvider.swift         # Anthropic, OpenAI-compatible, and local Ollama clients
├── Settings.swift            # provider, model, appearance, and shortcut settings
└── MeetingStore.swift        # local meeting history and context extraction
```

## Development

```bash
swift build
```

For a diagnostic-friendly overlay, turn on **Debug mode** in Settings and relaunch. Debug mode makes the overlay visible to screenshots so UI issues can be captured and investigated.

## Contributing

Issues and pull requests are welcome. Please keep changes macOS-native, avoid introducing unnecessary telemetry or remote infrastructure, and include a short verification note with UI or audio-related changes.

## License

Kura is available under the [MIT License](LICENSE).
