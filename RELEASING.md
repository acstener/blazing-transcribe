# Releasing (maintainer)

Blazing Transcribe ships as a signed, notarized `.dmg` with Sparkle
auto-updates. Releases are built from **this repo**; the marketing site +
update feed live in a **separate** site repo (Vercel).

## Prerequisites (maintainer machine)

- A "Developer ID Application" signing certificate in your keychain.
- A `notarytool` keychain profile (stores your Apple ID + app-specific password).
- The Sparkle EdDSA **private** key in your keychain (the public key is in the
  generated `Info.plist`; the private key is never stored in this repo).
- `Sources/App/AnalyticsSecrets.swift` present locally (copy from the `.example`
  and fill in the real PostHog key) so the official build reports analytics.
  Fork/community builds leave it empty and send nothing.
- A local checkout of the site repo (for the DMG + appcast output).

## Build + sign + notarize

```bash
SIGNING_IDENTITY="Developer ID Application: <Your Name> (TEAMID)" \
NOTARIZE_KEYCHAIN_PROFILE="<your-notary-profile>" \
SITE_DIR="/path/to/your/site-repo" \
./Scripts/build-release.sh 2.1.1
```

This builds release, bundles + signs the `.app`, packages the `.dmg`, notarizes
and staples it, then writes the DMG + regenerated Sparkle `appcast.xml` into
`$SITE_DIR/public/updates/`.

## Deploy

The site repo is what actually reaches users. Commit + push it:

```bash
cd "$SITE_DIR"
git add public/BlazingTranscribe.dmg public/updates/appcast.xml public/updates/BlazingTranscribe-<version>.dmg
git commit -m "Release v<version>"
git push          # Vercel redeploys; existing users auto-update within ~4h
```

Verify: `curl -s https://www.blazingfasttranscription.com/updates/appcast.xml | grep sparkle:version`
