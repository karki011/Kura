# Continue Kura on another Mac

Checkpoint: September 7, 2026. Work is on branch `kura-launch`, not `main`.
Read this before older, chronological entries in `IMPLEMENTATION_NOTES.md`.

## Get the code

```sh
git clone --branch kura-launch https://github.com/karki011/Kura.git
cd Kura
swift --version
bash check.sh
```

Use macOS 14.2 or later and a Swift 6.2-compatible toolchain (see `Package.swift`).
Read `RELEASING.md` before installing a build. Use only `/Applications/Kura.app`
for real privacy/capture testing; the production bundle ID is `com.karki011.kura`.
Do not launch older Kura Updated/Preview copies for acceptance testing.

## What is included

- Updated meeting workspace, context attachment flow, themed settings, logo,
  model and reasoning controls, saved history, wrap-up and speaker correction.
- OpenAI Responses and Anthropic BYO-key providers; local Ollama support.
- Free Apple transcription and optional local whisper.cpp/pyannote setup.
  No Deepgram requirement. Local ML models are not bundled or downloaded for you.
- Direct Core Audio capture plus a selectable Cloak compatibility path, capture
  diagnostics, and independent capture/recognition lifecycle guards.
- Short-pause speech endpointing and automatic question answering improvements.
- Regression tests, packaging scripts, and release instructions.

## Verified versus unfinished

- 31 Swift regression checks and 4 Python checks passed on the original Mac.
  Release compilation, bundle-signature verification, and installer packaging passed.
- The earlier installed build captured real system playback with **Cloak
  compatibility + Apple transcription**. Manual OpenAI Q&A with synthetic context
  worked. A spoken arithmetic question automatically returned the correct answer,
  but waited approximately 49 seconds before sending the request.
- The latest change ends an Apple speech turn after 1.2 seconds of stable text
  and 0.9 seconds of quiet system audio, then waits 250 ms before requesting an
  answer. These waits overlap where possible. The 55-second fallback remains for
  continuous/noisy input; this is heuristic endpointing, not semantic turn detection.
- The latest change also permits repeated questions in different turns, rejects
  duplicate final callbacks for the same line, recognizes more question starters,
  and queues the latest question for up to 15 seconds while a reply is active.
- **Real end-to-end latency of this new version is not yet verified.** Reinstalling
  the ad-hoc-signed update invalidated permissions and capture stalled at startup.
- Direct capture and actual local Whisper/pyannote inference still need device
  acceptance tests. The local backend retains chunk/processing latency.

## Signing is the immediate blocker

The last installed build was `20260907164801`, ad-hoc signed. Repeated ad-hoc
rebuilds changed its code identity and led to permission prompts or stale-looking
System Settings switches. Do not keep repeating that install/regrant loop.

A Developer ID Application `.cer` was imported on the original Mac, but both
default and explicit login-Keychain checks found **zero matching signing
identities**. Its matching private key was not available. No new CSR/certificate
or private key was created, and no existing certificate was revoked.

On the next Mac, either use an existing certificate/private-key pair already
available in its Keychain, or create a new CSR there and issue a Developer ID
Application certificate with Apple's current G2 intermediary. A `.cer` or Team ID
alone cannot sign code. Never commit a private key or password.

```sh
security find-identity -v -p codesigning
KURA_APP_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash release.sh --signed
```

Use the same identity and bundle ID for subsequent builds. Verify grants survive
a second signed update. Developer ID Installer and notarization are separate
public-distribution steps documented in `RELEASING.md`.

## Local data does not travel through this repository

API keys stay in macOS Keychain. Enter your own OpenAI/Anthropic key again on the
next Mac; never put it into a source file or chat. App preferences, permission
grants, signing identities, and local speech models are not in Git.

Meetings/context packs live in `~/Library/Application Support/Kura/Meetings` on
the original Mac. They were deliberately not uploaded. Transfer them privately
only if wanted, with Kura closed on both Macs and a backup of the destination.
Generated apps, installer packages, build caches, and old-app backups are ignored.

## Next acceptance test

1. Resolve stable signing, install the signed app, and grant the needed access.
2. Choose Apple transcription; start with the previously working Cloak
   compatibility capture option. Enter a BYO OpenAI key and test its connection.
3. In a new synthetic meeting, enable Auto answer, start Listen, and play a short
   question such as "What is two plus two? Please answer briefly."
4. Measure speech end → final transcript → request → first visible answer. Check
   for one answer, continued capture, a follow-up, and a repeated question.
5. Test pauses mid-sentence, background noise, a busy provider, Auto answer off,
   Pause, switching history, and error/retry behavior. Keep real meeting material
   out of synthetic API tests.

The overlay's always-on-top level can obscure macOS permission dialogs. The
More menu includes Quit Kura. Avoid assuming an orange status means the user
never granted access; verify the currently running signed copy.
