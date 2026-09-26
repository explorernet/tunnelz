# Releasing Tunnelz

Pushing a tag builds, signs, notarizes and publishes a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow (`.github/workflows/release.yml`) uploads `Tunnelz-<version>.dmg` and `appcast.xml`
to the GitHub release. Installed apps read
`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` and update themselves
with Sparkle.

## One-time setup

Add these under **Settings → Secrets and variables → Actions** in the GitHub repository.

### Sparkle (required)

Sparkle only installs updates signed with this key. Generate it once, after building the
project in Xcode so the Sparkle package is downloaded:

```bash
SPARKLE_BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/Tunnelz-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)
"$SPARKLE_BIN/generate_keys"                        # prints the public key; the private key goes to your keychain
"$SPARKLE_BIN/generate_keys" -x sparkle_private_key # exports the private key to a file
```

| Name | Kind | Value |
|---|---|---|
| `SPARKLE_PUBLIC_KEY` | Variable | The public key printed by `generate_keys` |
| `SPARKLE_PRIVATE_KEY` | Secret | Contents of `sparkle_private_key` (delete the file afterwards) |

Never change the key after the first release: installed copies would reject every later update.
Keep a backup of the private key (it stays in your login keychain as "Private key for signing Sparkle updates").

### Developer ID signing and notarization (recommended)

Without these, the workflow still publishes an ad-hoc signed build, but macOS blocks it on first open.

1. **Developer ID Application certificate** (Account Holder only): create it at
   developer.apple.com → Certificates, then export it from Keychain Access as a `.p12` with a password.
2. **App Store Connect API key**: App Store Connect → Users and Access → Integrations →
   App Store Connect API, role *Developer*. Download the `.p8` (only possible once).

```bash
base64 -i DeveloperID.p12 | pbcopy   # paste into DEVELOPER_ID_P12_BASE64
base64 -i AuthKey_XXXX.p8 | pbcopy   # paste into NOTARY_KEY_P8_BASE64
```

| Name | Kind | Value |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | Secret | Base64 of the `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | Secret | The `.p12` password |
| `APPLE_TEAM_ID` | Secret | Team ID from Membership details |
| `NOTARY_KEY_P8_BASE64` | Secret | Base64 of the `.p8` |
| `NOTARY_KEY_ID` | Secret | The API key's Key ID |
| `NOTARY_ISSUER_ID` | Secret | The Issuer ID shown above the keys list |

## Versions

- `CFBundleShortVersionString` comes from the tag (`v1.2.0` → `1.2.0`).
- `CFBundleVersion` is the workflow run number, so it always increases; Sparkle compares it to decide what is newer.
- Local and Debug builds have no Sparkle key, so the updater is off and "Check for Updates…" is disabled.
