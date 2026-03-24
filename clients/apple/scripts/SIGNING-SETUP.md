# Signing Setup for Oppi Mac Distribution

This document covers the one-time setup required before `release-mac.sh` can produce
a Gatekeeper-accepted DMG for distribution outside the App Store.

## Current state

- **Code signing identity**: ad-hoc (`-`). Builds and runs locally but does not pass Gatekeeper.
- **Missing**: Developer ID Application certificate and notarization credentials.
- **Notarization**: skipped until the above are in place.

---

## Step 1 — Create a Developer ID Application certificate

1. Go to [developer.apple.com/account/resources/certificates/list](https://developer.apple.com/account/resources/certificates/list).
2. Click **+** to add a new certificate.
3. Choose **Developer ID Application** under *Software*.
4. Follow the prompts to generate a Certificate Signing Request (CSR) from Keychain Access on this machine.
5. Upload the CSR, then download the resulting `.cer` file.
6. Double-click the `.cer` file to install it in your login Keychain.
7. Verify:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   # Expected: "Developer ID Application: Da Chen (AZAQMY4SPZ)"
   ```

---

## Step 2 — Update project.yml signing settings

Once the cert is installed, update `ios/project.yml` in the `OppiMac` target's `settings.base`:

```yaml
CODE_SIGN_IDENTITY: "Developer ID Application"
DEVELOPMENT_TEAM: AZAQMY4SPZ
```

Remove or leave `-` replaced entirely. Then regenerate:

```bash
cd ios && xcodegen generate
```

Build to confirm signing works:

```bash
xcodebuild -project Oppi.xcodeproj -scheme OppiMac \
  -destination "platform=macOS" build
```

---

## Step 3 — Store notarization credentials

You need an Apple app-specific password for notarytool (not your Apple ID password).

1. Go to [appleid.apple.com](https://appleid.apple.com) → **Sign-In and Security → App-Specific Passwords**.
2. Generate a password named `oppi-notary`.
3. Store it in your Keychain:
   ```bash
   xcrun notarytool store-credentials "oppi-notary" \
     --apple-id <your-apple-id-email> \
     --team-id AZAQMY4SPZ \
     --password <app-specific-password>
   ```
4. Verify:
   ```bash
   xcrun notarytool history --keychain-profile "oppi-notary"
   ```
   This should return a (possibly empty) list of prior submissions without errors.

---

## Step 4 — Run the release script

Once Steps 1–3 are complete:

```bash
cd ios
bash scripts/release-mac.sh 1.0.0
```

This will:
1. Regenerate the Xcode project
2. Archive the OppiMac scheme with `MARKETING_VERSION=1.0.0`
3. Export a Developer ID–signed `.app`
4. Package it into `build/Oppi-1.0.0.dmg`
5. Code-sign the DMG
6. Sign with Sparkle EdDSA (for update verification)
7. Generate/update `scripts/appcast/appcast.xml`
8. Submit the DMG to Apple for notarization (waits for result)
9. Staple the notarization ticket

### Final verification

```bash
spctl -a -t open --context context:primary-signature build/Oppi-1.0.0.dmg
# Expected: build/Oppi-1.0.0.dmg: accepted
```

---

## Build pipeline validation (ad-hoc signing)

Tested on 2026-03-17 with `bash scripts/release-mac.sh 1.0.0 --skip-notarize`:

| Step | Result |
|------|--------|
| Step 1 — xcodegen generate | ✅ Passes |
| Step 2 — archive | ✅ Passes (ad-hoc signing) |
| Step 3 — export Developer ID app | ❌ Fails: "No signing certificate Developer ID Application found" |

Steps 4–9 (DMG, signing, notarization) cannot be tested without the cert.
This is expected. Install the Developer ID Application certificate (Step 1 above)
and the full pipeline will work.

---

## Troubleshooting

### Archive fails with "No signing certificate ... found"
- The Developer ID Application cert is not installed. Repeat Step 1.
- Run `security find-identity -v -p codesigning` to confirm.

### Export fails: "No applicable devices found" or provisioning error
- Check `ExportOptions-Mac.plist` has `method: developer-id` and correct `teamID: AZAQMY4SPZ`.
- Developer ID export does not require a provisioning profile for non-sandboxed apps.

### Notarization fails: "Unable to find keychain profile"
- The profile name must match exactly: `oppi-notary`.
- Re-run `xcrun notarytool store-credentials "oppi-notary" ...`.

### Sparkle tools not found
- `release-mac.sh` looks for Sparkle in `~/Library/Developer/Xcode/DerivedData/Oppi-*/`.
- Build the OppiMac scheme in Xcode once to resolve the Swift package and populate DerivedData.

### DMG not accepted by Gatekeeper after notarization
- Ensure `xcrun stapler staple` ran successfully (Step 9 in the script).
- Re-check: `spctl -a -t open --context context:primary-signature build/Oppi-1.0.0.dmg`
