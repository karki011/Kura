# Free local transcription + speaker labels

Kura supports whisper.cpp for text and pyannote Community-1 for speaker separation.
There is no speech API subscription. This setup requires command-line tools, disk
space for model downloads, and enough CPU/RAM to process audio. It is not bundled
with model weights. The Apple transcription option remains available without setup.

## 1. Install whisper.cpp

Follow https://github.com/ggml-org/whisper.cpp#quick-start to build whisper-cli
and download a compatible ggml model. Start with base.en for English or base for
multiple languages. Larger models may not keep up with a live call on your Mac.
In Settings → Audio select the full path to build/bin/whisper-cli and the .bin model.

## 2. Prepare pyannote

Use a dedicated Python 3.10+ virtual environment with pyannote.audio 4.x:

    python3 -m venv /your/chosen/path/kura-speech-env
    /your/chosen/path/kura-speech-env/bin/python -m pip install 'pyannote.audio>=4,<5'

Follow the upstream platform dependency instructions at
https://github.com/pyannote/pyannote-audio if installation reports missing libraries.
Select this environment's bin/python in Settings, not the macOS system Python.

## 3. Download Community-1 yourself

Visit https://huggingface.co/pyannote/speaker-diarization-community-1 and review
the model access conditions. They require a Hugging Face account and sharing
contact information. You must accept these yourself. The model is CC-BY-4.0;
keep its attribution when redistributing it. Kura does not redistribute weights.

Follow the model card's **Offline use** instructions to download the complete
repository using Git LFS. A directory containing only Git LFS pointer files is
not sufficient. Select the downloaded directory containing config.yaml in Kura.
Keep authentication in your Hugging Face/Git tooling, never in meeting notes.

## 4. Use it

Choose **Local · Whisper + pyannote** in Settings → Audio, fill all four paths,
then choose Check paths. That checks file presence, not model compatibility.
Click Listen to load the models and begin. Loading errors appear in the workspace.

- System audio is processed in 30-second rolling windows submitted every 10 seconds.
  Text and labels appear together after processing; this is not word-by-word streaming.
- Speaker labels are matched using overlapping speech between windows. They are
  tentative; a person returning after a long silence can receive a new label.
  Labels reset when listening reconnects. Confirm names manually or using captions.
- Auto answer uses finalized remote questions, when enabled, with your selected AI
  provider. Choose Ollama with a local model if you also want no paid answer API.
- Temporary audio windows exist on disk while processing and are removed afterwards
  or on normal stop/error. A crash may leave KuraLocalAudio-* folders in macOS temp.
- The worker loads only local models with Hugging Face offline mode and telemetry
  disabled. It does not send audio to a speech service. A cloud answer provider
  still receives the text/context used for Q&A.
- Optional **Include my microphone** still uses Apple speech recognition separately;
  Apple may use its servers when on-device recognition is unavailable. Leave this
  off if you require a fully local system-audio-only workflow.
- If local inference falls behind, Kura stops with an error instead of silently
  dropping audio. Pause/quit may wait for the final chunk, up to the worker timeout.

## Attribution

- whisper.cpp: https://github.com/ggml-org/whisper.cpp (MIT)
- pyannote.audio: https://github.com/pyannote/pyannote-audio (MIT)
- Community-1: https://huggingface.co/pyannote/speaker-diarization-community-1 (CC-BY-4.0)
