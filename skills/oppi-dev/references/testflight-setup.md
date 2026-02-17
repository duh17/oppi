# TestFlight Setup

One-time prerequisites for `ios/scripts/testflight.sh`.

## App Store Connect API Key

1. Go to https://appstoreconnect.apple.com/access/integrations/api
2. Generate API Key with **Admin** role (needed to auto-create Distribution cert)
3. Download the `.p8` file
4. Store it:
   ```bash
   mkdir -p ~/.appstoreconnect
   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/
   ```
5. Set environment variables (fish):
   ```fish
   set -Ux ASC_KEY_ID "XXXXXXXXXX"
   set -Ux ASC_ISSUER_ID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```
   The Issuer ID is shown at the top of the API Keys page in App Store Connect.

## App Store Connect App

Create the app in App Store Connect if not already done:
- My Apps → "+" → New App
- Platform: iOS
- Name: Oppi (or Oppi after rename)
- Bundle ID: `dev.chenda.Oppi`
- SKU: `piremote`

## Team & Signing

- Team ID: `AZAQMY4SPZ`
- Development cert: `Apple Development: Da Chen (YHJ35BKTZL)`
- Distribution cert: auto-created by `-allowProvisioningUpdates` on first TestFlight build

## Usage

```bash
ios/scripts/testflight.sh --bump          # build + upload, increment build number
ios/scripts/testflight.sh --build-only    # archive + export IPA only
ios/scripts/testflight.sh --build-number 42  # explicit build number
```

Build artifacts go to `ios/build/testflight-<timestamp>/` (gitignored).
