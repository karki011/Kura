"""Protocol fixture only: does not import models or transcribe real speech."""
import json
import os
import sys
import wave

for line in sys.stdin:
    request = json.loads(line)
    with wave.open(request["file"], "rb") as audio:
        assert audio.getnchannels() == 1
        assert audio.getsampwidth() == 2
    os.unlink(request["file"])
    print(json.dumps({"segments": [{"speaker": 0, "text": "What is the launch date?", "start": request["cutoff"]}]}), flush=True)
