# Building and updating Kura

Use one installed app, `/Applications/Kura.app`, for everyday use. Development
previews use a separate bundle identifier; do not use them for real meetings.
Keep the production identifier `com.karki011.kura` so preferences and stored
meetings remain associated with the same app. Keys remain in macOS Keychain.

## Local build

Run `bash release.sh --local`. This builds the release executable, runs the
regression checks, bundles `.build/release-app/Kura.app`, verifies its signature,
and creates `dist/Kura-1.0.0.pkg`. Existing app bundles and installer artifacts
are backed up rather than deleted. The script does not install or launch anything.

The installer targets `/Applications`. Quit existing Kura copies before installing.
Installing replaces any Kura at that location; preserve that app first if needed.
Launch the installed Kura and verify permissions and actual transcription after
installation. A successful build is not proof that live audio or Q&A works.

Without a signing identity, this is an ad-hoc signed app in an unsigned installer,
not a notarized public release. Moving it into Applications does not by itself
fix macOS trust or guarantee permissions survive updates.

## Stable signing

Configure a codesigning certificate in Keychain, then run:

```sh
KURA_APP_SIGNING_IDENTITY='Your signing identity' bash release.sh --signed
```

The signed workflow requires an explicit identity to avoid silently falling back
to ad-hoc signing. Certificate creation and trust configuration are user-managed;
the build scripts do not create credentials or change security settings.

For public distribution, use Developer ID Application signing. Set
`KURA_INSTALLER_SIGNING_IDENTITY` to a Developer ID Installer identity for the
installer. Set `KURA_NOTARY_PROFILE` to an existing notarytool Keychain profile
to submit and staple the installer. Public signing/notarization requires separate
setup and is not accomplished by `--local` or by a local self-signed certificate.

Override `KURA_VERSION` for releases; `KURA_BUILD_NUMBER` defaults to a timestamp.
Preserve the signing identity and installed location across updates. Permission
retention must still be tested; users may need to grant access again when moving
from an older ad-hoc build.
