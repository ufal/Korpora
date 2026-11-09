# Updates with Sparkle (built 2026-11-09, for 0.5)

Korpora checks for new versions with [Sparkle](https://sparkle-project.org) 2.10.1 (Swift package, pinned exactly in
`Korpora/project.yml`; the version is also pinned by `Package.resolved`). Non-sandboxed, hardened runtime, Developer ID,
notarized DMG: the plain case, no sandbox keys.

## In the app
- `Info.plist`: `SUFeedURL` = `https://github.com/ufal/Korpora/releases/latest/download/appcast.xml`, `SUPublicEDKey` = the public half of the
  signing key. Automatic checks are left at Sparkle's default: on the second launch it asks the user whether to check by itself.
- App menu: "Check for Updates…" after "About Korpora" (`AppDelegate.checkForUpdates`, an `SPUStandardUpdaterController`).
- A **Debug** build never starts the updater by itself (it would offer to replace the build being tried); the menu item still works there
  (it starts the updater on the first click).
- Nothing is kept next to the user's corpora: Sparkle's state is in the app's defaults and the system caches.

## The signing key
- EdDSA, made once with Sparkle's `generate_keys`; the private half lives in the **login Keychain** (item "https://sparkle-project.org",
  account `ed25519`). Public key: see `Info.plist`.
- **Back it up once, outside the repo and in a visible place** (a password manager, an encrypted disk image): with the tools from the
  package, `generate_keys -x <file>` (the tools are in
  `~/Library/Developer/Xcode/DerivedData/Korpora-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`). Without the private key no installed copy
  accepts an update; a new key would need every user to install by hand again. To restore on another Mac: `generate_keys -f <file>`.

## A release
`scripts/make-release.sh` does the Sparkle part:
1. Re-signs Sparkle's nested code (Updater.app, Autoupdate, the two XPC services: ad-hoc signed in the package, which the notary service
   rejects) and the framework, inside-out with Developer ID, a secure timestamp and the hardened runtime, then the app; the signature
   checks cover all of it.
2. Before the long notarization: the keychain's key must equal the app's `SUPublicEDKey`, or the script stops.
3. After the DMG is notarized and stapled (the signature covers its final bytes): `generate_appcast` over a folder holding the DMG (and
   `docs/release-notes/<version>.md` when there is one, embedded) writes `release/appcast.xml`; the script checks it carries an
   `sparkle:edSignature`. With `--skip-notarize` no appcast is written.

**Upload both** `Korpora-<version>.dmg` and `appcast.xml` to the GitHub release (the one marked Latest): the app reads
`releases/latest/download/appcast.xml`. A release without `appcast.xml` breaks updates for everyone until the next one has it.

`CFBundleVersion` (the build number) **must increase with every release**: Sparkle compares it, not the short version.

## Notes
- 0.5 is the first build that can update itself; users of 0.4.x install it by hand once.
- The appcast holds one item (the newest release). Enough: a user is always offered the latest.
- Not tried yet: a full release build with the new steps, and an update from one build to the next (needs two releases; try 0.5 to 0.5.1).
