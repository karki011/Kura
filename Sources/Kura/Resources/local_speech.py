"""Offline JSON-lines worker. No credentials, downloads, or network API calls.

Input: a 16-bit mono WAV path, absolute window offset, and prior cutoff (seconds).
Output: {segments: [{speaker: int, text: str, start: seconds}]} or {error: str}.
Speaker identity is matched only through overlapping windows, not voice enrollment.
"""
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import wave


def match_speakers(turns, previous, next_id):
    scores = {}
    for start, end, label in turns:
        for old_start, old_end, identity in previous:
            overlap = max(0.0, min(end, old_end) - max(start, old_start))
            if overlap:
                scores[label, identity] = scores.get((label, identity), 0) + overlap
    mapping, used = {}, set()
    for (label, identity), score in sorted(scores.items(), key=lambda item: item[1], reverse=True):
        if score >= 0.3 and label not in mapping and identity not in used:
            mapping[label] = identity
            used.add(identity)
    for _, _, label in turns:
        if label not in mapping:
            mapping[label] = next_id
            next_id += 1
    return [(start, end, mapping[label]) for start, end, label in turns], next_id


def align_words(transcription, turns, offset, cutoff):
    result = []
    for segment in transcription:
        # Full JSON contains token timestamps; fall back for older whisper-cli builds.
        words = segment.get("tokens") or [segment]
        for word in words:
            text = word.get("text", "")
            bounds = word.get("offsets", {})
            start = offset + bounds.get("from", 0) / 1000
            end = offset + bounds.get("to", 0) / 1000
            if not text.strip() or text.strip().startswith("[_") or text.strip().startswith("<|") or end <= start:
                continue
            if (start + end) / 2 < cutoff:
                continue
            candidates = [(max(0, min(end, b) - max(start, a)), speaker) for a, b, speaker in turns]
            overlap, speaker = max(candidates, default=(0, -1))
            if overlap <= 0:
                speaker = -1
            if result and result[-1]["speaker"] == speaker and start - result[-1]["end"] < 1.5:
                result[-1]["text"] += text
                result[-1]["end"] = end
            else:
                result.append({"speaker": speaker, "text": text, "start": max(start, cutoff), "end": end})
    return [{"speaker": item["speaker"], "text": item["text"].strip(), "start": item["start"]} for item in result]


def main():
    whisper, whisper_model, speaker_model = sys.argv[1:4]
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", PYANNOTE_METRICS_ENABLED="0")
    protocol_output = sys.stdout
    # Model libraries sometimes print progress. Keep protocol output strictly JSON.
    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        import torch
        from torchaudio.functional import resample
        from pyannote.audio import Pipeline
        pipeline = Pipeline.from_pretrained(speaker_model)
        if pipeline is None:
            raise RuntimeError("Could not load the local Community-1 pipeline.")
        torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
    previous, next_id = [], 0
    for line in sys.stdin:
        request = json.loads(line)
        source = request["file"]
        try:
            with contextlib.redirect_stdout(sys.stderr):
                with wave.open(source, "rb") as audio:
                    if audio.getsampwidth() != 2 or audio.getnchannels() != 1:
                        raise ValueError("Expected mono 16-bit PCM audio")
                    rate = audio.getframerate()
                    samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768
                if len(samples) == 0 or np.sqrt(np.mean(samples ** 2)) < 0.001:
                    segments = []
                else:
                    waveform = torch.from_numpy(samples).unsqueeze(0)
                    if rate != 16000:
                        waveform = resample(waveform, rate, 16000)
                    with tempfile.TemporaryDirectory(prefix="kura-inference-", dir=os.path.dirname(source)) as temp:
                        wav_path = os.path.join(temp, "audio.wav")
                        with wave.open(wav_path, "wb") as audio:
                            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
                            audio.writeframes((waveform.squeeze(0).numpy().clip(-1, 1) * 32767).astype("<i2").tobytes())
                        output_path = os.path.join(temp, "transcript")
                        completed = subprocess.run([whisper, "-m", whisper_model, "-f", wav_path, "-ojf", "-of", output_path, "-l", "auto"],
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=90)
                        if completed.returncode:
                            raise RuntimeError("whisper-cli failed. Check the executable and model compatibility.")
                        with open(output_path + ".json", encoding="utf-8") as result:
                            transcription = json.load(result)["transcription"]
                    with torch.inference_mode():
                        output = pipeline({"waveform": waveform, "sample_rate": 16000})
                    offset = request["offset"]
                    turns = [(turn.start + offset, turn.end + offset, speaker) for turn, speaker in output.exclusive_speaker_diarization]
                    previous, next_id = match_speakers(turns, previous, next_id)
                    segments = align_words(transcription, previous, offset, request["cutoff"])
            print(json.dumps({"segments": segments}), file=protocol_output, flush=True)
        except Exception as error:
            print(json.dumps({"error": str(error)}), file=protocol_output, flush=True)
            return 1
        finally:
            try:
                os.unlink(source)
            except FileNotFoundError:
                pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"error": "Local model setup failed: " + str(error)}), flush=True)
        sys.exit(1)
