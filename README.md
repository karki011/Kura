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

- Native, movable, translucent macOS workspace with light, dark, and system appearance
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
- **Screen Recording** is optional and supports observation of your selected meeting window

Open settings with `⌃⌥,`, add your provider key, choose a model, and start a session.

You can open the workspace and type without granting audio permissions; Kura requests those when you use audio features. The menu-bar icon brings Kura back whenever you need it.

### A clearer meeting workflow

1. **Prepare:** name the meeting, set a goal, and choose a Planning, Customer Call, or Brainstorm template. Use **Add context** for notes, pasted text, and multiple PDF/text attachments. Drop files onto the workspace to attach them. Each attachment has a preview and removal control; extraction and AI context limits are shown explicitly.
2. **Listen:** use **Listen** to capture system audio. Under **More → Meeting capture**, optionally include your microphone as **You**. Use a headset to reduce duplicated audio. **Catch me up**, **Suggest a response**, and **Capture decision** keep assistance close to the transcript. Visible Send and Stop controls preserve unsent text while an answer runs.
3. **Wrap up:** generate editable Summary, Decisions, Action Items, and Open Questions. Tasks have owners, deadlines, completion states, and supporting transcript links when the model supplies valid references. Generate an editable follow-up draft and copy it when ready.
4. **Revisit:** search meeting titles, notes, tags, and transcripts. Rename or favorite meetings, ask questions using a saved meeting’s context, and export that selected meeting to Markdown. Deletion moves files to Kura’s local Trash, with an Undo action.

Live sessions autosave locally and restore after relaunch. Full transcripts are retained; long wrap-ups process the transcript in sections instead of only using the final few minutes. Meeting history is also saved when wrapping up or starting another session. The overlay remembers its position and offers a compact view. Auto appearance follows macOS without background screen sampling.

### Speaker labels and meeting windows

Apple transcription is the default and does **not** separate individual remote speakers. They appear as **Unknown speaker**. Optional continuous microphone capture labels your voice **You**.

For free on-device transcription **and** speaker separation, choose **On-device · speaker labels** in Settings → Audio. Parakeet streaming ASR and Sortformer diarization run as CoreML models on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio); the models download once on first use and work offline afterwards. [On-device speech notes](Sources/Kura/Resources/LOCAL_SPEECH_SETUP.md) have the details. No Python or manual model setup is required. Deepgram has been removed.

On-device text streams live and each utterance commits with its speaker label shortly after the speaker pauses. Labels (up to 4 speakers) are stable within a session but tentative; returning speakers after long pauses may receive a new label, and names still need confirmation. Audio never leaves the Mac. Optional microphone inclusion remains a separate Apple recognition path.

**Listen** updates the transcript. Turn on **Auto answer** to answer detected finalized remote questions using your selected AI provider, or ask a typed question. Disabling Auto answer leaves transcription running without automatic AI requests.

For optional name suggestions, choose **More → Meeting capture → Refresh**, select your Zoom, Google Meet, Teams, or other meeting window, then choose **Observe selected window**. Screen Recording permission is required. Kura uses Apple Vision locally to read visible text; screenshots are not stored or sent to an AI provider. Turn on meeting captions to improve matching. Explicit speaking labels and matching caption text can suggest a name, but Kura does not infer names from faces or automatically assign identities. Click a speaker label to confirm/correct a name and optionally rename that speaker throughout the session.

Window layouts, hidden captions, overlapping speech, and recognition quality affect results. This is not a native Zoom/Meet participant integration. System audio may include other apps. Preview testing uses synthetic data; real multi-speaker calls still need validation with your setup.

### Reusable context

Save notes, a goal, and attachments as a named **context pack** inside Add context. Apply a pack explicitly to another meeting; context is never silently carried into a new session. PDF extraction supports selectable text, not scanned-image OCR. Imports allow up to 20 MB per file and retain up to 30,000 characters per attachment; the AI background budget is 40,000 characters across goal, notes, and attachments, with an in-app warning when exceeded.

### Use a local model with Ollama

1. Install and start [Ollama](https://ollama.com), then pull a model—for example: `ollama pull llama3.2`.
2. In Kura Settings, set **Provider** to **Ollama (local)**.
3. Keep the default server address (`http://127.0.0.1:11434`) or enter the address of your Ollama server.
4. Kura detects installed models and automatically uses one as its default. You can optionally choose another detected model in Settings. No API key is required.

Ollama traffic stays between Kura and the server address you configure. You can still use the OpenAI-compatible provider for other local runtimes that expose that API, such as LM Studio.

### Connect a custom OpenAI-compatible provider

For **Anthropic/Claude** or **OpenAI**, choose its dedicated provider in Settings → AI setup, save your own key, and choose **Refresh available models**. The searchable catalog lists all models returned for that key, with manual model-ID entry as a fallback. Claude reasoning options come from model capabilities. OpenAI’s catalog does not report per-model effort support, so its effort selector shows API options with a model-compatibility warning; **Provider default** omits the parameter. OpenAI uses the Responses API. The catalog can include non-text models that are unsuitable for meeting Q&A.

You control the output/reasoning token cap and effort. API usage is billed by your provider; Kura supplies no credits or subscription. Choose local Ollama for answers if you want no paid answer API. Keys for Anthropic, direct OpenAI, and custom endpoints are stored separately in Keychain.

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
bash check.sh
```

`check.sh` runs the standalone Swift regression suite with Command Line Tools; it does not require XCTest or full Xcode. It covers persistence/migration, long transcripts, cancellation, context isolation, speaker parsing, and wrap-up tasks. `bundle.sh` preserves an existing app under `.build/app-backups/` before replacing it. See [implementation notes](IMPLEMENTATION_NOTES.md) for validation and current limitations.

For a diagnostic-friendly overlay, turn on **Debug mode** in Settings and relaunch. Debug mode makes the overlay visible to screenshots so UI issues can be captured and investigated.

## Contributing

Issues and pull requests are welcome. Please keep changes macOS-native, avoid introducing unnecessary telemetry or remote infrastructure, and include a short verification note with UI or audio-related changes.

## License

Kura is available under the [MIT License](LICENSE).
