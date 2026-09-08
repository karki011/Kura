# On-device transcription + speaker labels

Kura's **On-device · speaker labels** option (Settings → Audio → Listen with) transcribes
system audio entirely on your Mac and labels up to 4 remote speakers live. It replaces the
earlier do-it-yourself whisper.cpp + pyannote setup; no Python, command-line tools, model
accounts, or manual downloads are needed.

## What runs

- **Parakeet EOU 120M** streaming speech recognition (English), and
- **Sortformer v2.1** streaming speaker separation,

both as CoreML models on the Apple Neural Engine, integrated through FluidAudio
(https://github.com/FluidInference/FluidAudio, Apache-2.0).

## First use

The models download automatically from Hugging Face the first time you start Listen with
this option (a few hundred MB, once). Listen shows download progress and starts capturing
when the models are ready. After that, transcription works fully offline.

If a download is interrupted, just start Listen again — partial downloads are resumed or
re-fetched safely. Model files live in
`~/Library/Application Support/FluidAudio/Models`; deleting that folder forces a fresh
download on next use.

## Behavior

- Text streams live and each utterance is committed with its speaker label a moment
  after the speaker pauses (roughly 1–2 seconds).
- Speaker labels (Speaker 1–4) are stable within a listening session and tentative:
  confirm or rename them in the transcript. A brand-new session starts numbering over.
- Sortformer supports at most 4 simultaneous speakers; beyond that, voices may be merged.
- No audio ever leaves the Mac. A cloud answer provider still receives the transcript
  text used for Q&A, per your AI setup.
- The system audio tap only delivers audio while sound is actually playing; in silence
  the level meter stays still and no new text appears. That is normal.
- Optional **Include my microphone** still uses Apple speech recognition separately;
  Apple may use its servers when on-device recognition is unavailable. Leave this off if
  you require a fully on-device workflow.

## Attribution

- FluidAudio: https://github.com/FluidInference/FluidAudio (Apache-2.0)
- Parakeet EOU: NVIDIA parakeet_realtime_eou_120m-v1, CoreML conversion by FluidInference
- Sortformer: https://arxiv.org/abs/2409.06656 (NVIDIA Open Model License)
