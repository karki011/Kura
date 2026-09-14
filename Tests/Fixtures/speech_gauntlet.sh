#!/bin/bash
# Three-speaker stress test for Kura's capture pipeline: varied pace, rapid
# turn-taking, a long monologue, and a planted question for auto answer.
# Voices: Samantha (normal), Fred (fast), Daniel (slow British).

# 1. Normal-pace opener
say -v Samantha "Let's kick off. Today we need to cover the release timeline, the budget review, and who owns the migration."
sleep 1.5

# 2. Fast speaker
say -v Fred -r 250 "I ran the numbers quickly and the budget is basically fine we are about eight percent under so no blocker there."
sleep 1.5

# 3. Slow speaker
say -v Daniel -r 140 "I would like to raise one concern. The migration plan still has no rollback step, and that worries me."
sleep 1.5

# 4. Rapid short back-and-forth (1s gaps, short turns)
say -v Samantha -r 230 "Fair point."
sleep 1
say -v Fred -r 260 "Agreed, we need it."
sleep 1
say -v Daniel -r 150 "Can someone write it?"
sleep 1
say -v Fred -r 260 "I can draft it tonight."
sleep 1.5

# 5. Long monologue (tests continuous-speech commits, ~15s of speech)
say -v Samantha "Here is the full timeline as I see it. This week we freeze the feature branch and finish the migration draft. Next week the release candidate goes to the beta group, and we watch the error rates closely. The week after that, if nothing catches fire, we ship to everyone and publish the notes."
sleep 2

# 6. Planted question (auto answer should respond from context)
say -v Daniel -r 150 "So just to confirm, when exactly do we ship to everyone?"
sleep 6

# 7. Overlapping-style quick succession (minimal gaps)
say -v Fred -r 255 "Third week from now."
sleep 0.6
say -v Samantha -r 235 "Correct, assuming beta stays clean."
sleep 0.6
say -v Daniel -r 150 "Alright, that works for me."
sleep 1.5

# 8. Close
say -v Samantha "Great. Fred owns the rollback draft, Daniel reviews the migration plan, and I will send the summary. Thanks everyone."
echo "gauntlet playback done"
