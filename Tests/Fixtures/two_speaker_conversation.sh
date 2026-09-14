#!/bin/bash
# Two-speaker conversation played through the speakers for Kura's system-audio tap.
# Alternating voices with silence gaps so each utterance commits as its own turn.
say -v Samantha "Good morning everyone, let's start with the launch checklist."
sleep 2
say -v Fred "Thanks. I reviewed the build last night and the installer looks solid."
sleep 2
say -v Samantha "Great. What about the notarization step, did that finish cleanly?"
sleep 2
say -v Fred "Yes, the package was notarized and stapled without any errors."
sleep 2
say -v Samantha "Perfect. Then the only remaining item is the release notes draft."
sleep 2
say -v Fred "I can take that today and send it for review by the afternoon."
sleep 2
say -v Samantha "Sounds good. Let's wrap up and reconvene tomorrow morning."
echo "conversation playback done"
