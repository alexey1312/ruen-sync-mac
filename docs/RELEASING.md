# Releasing

CI/CD overview and the optional secret bundles needed to fully automate a
release. None of this is required to **use** RuEnSync — only to ship it.

## Workflows

- **`ci.yml`** — runs on every push/PR: `mise run format-check`, `lint`, `test`,
  debug build. Uses `macos-26` runners and Xcode 26.
- **`release.yml`** — triggers on `v*` tags. Rewrites
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `Project.swift` from the tag,
  builds Release, optionally signs + notarizes, packages a DMG, creates a GitHub
  Release, publishes the Sparkle appcast, and bumps the
  [Homebrew cask](https://github.com/alexey1312/homebrew-tap/blob/main/Casks/ruensync.rb).

## Cutting a release

```bash
git tag v1.2.3
git push origin v1.2.3
```

That's it — the workflow does the rest. No bump-PR needed; the tag is the
source of truth for the shipped version.

## Optional: Developer ID signing & notarization

Without these the DMG is **ad-hoc signed** and triggers the one-time Gatekeeper
approval flow described in `README.md → First launch`. With them, the DMG is
fully notarized and stapled, and Gatekeeper approves silently.

| Secret                     | Where to get                                                                     |
| -------------------------- | -------------------------------------------------------------------------------- |
| `BUILD_CERTIFICATE_BASE64` | `base64 -i DeveloperIDApplication.p12` (your exported Developer ID cert)         |
| `P12_PASSWORD`             | The password you set when exporting the .p12                                     |
| `KEYCHAIN_PASSWORD`        | Any random string — used to lock/unlock the temporary CI keychain                |
| `DEV_ID_APP`               | `Developer ID Application: Your Name (TEAMID)` (the exact common name)           |
| `APPLE_ID`                 | Your Apple ID email                                                              |
| `APP_PASSWORD`             | App-specific password from appleid.apple.com → Security → App-Specific Passwords |
| `TEAM_ID`                  | 10-character team identifier (in your developer account)                         |

## Optional: Homebrew cask bump

| Secret               | Purpose                                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `HOMEBREW_TAP_TOKEN` | PAT with `repo` scope on `alexey1312/homebrew-tap`. Lets the workflow push a commit bumping `Casks/ruensync.rb`. |

If unset, the release still ships — only the auto-bump of the tap is skipped.

## Sparkle auto-updates (one-time setup)

The app uses [Sparkle 2](https://sparkle-project.org). Each DMG is signed with
an EdDSA private key in CI; the corresponding public key is baked into
`Project.swift` and checked by Sparkle inside the running app before applying
any update.

**1. Generate a keypair (run once, locally):**

```bash
brew install --cask sparkle
generate_keys                              # prints the public key
generate_keys -p                           # prints the same public key for paste
generate_keys -x sparkle_private_key.pem   # exports the private key to a file
```

**2. Paste the public key into `Project.swift`** — replace
`REPLACE_ME_WITH_GENERATED_PUBLIC_ED_KEY` with the value `generate_keys -p`
printed.

**3. Store the private key as a GitHub secret:**

```bash
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.pem
rm sparkle_private_key.pem
```

**4. Create the `gh-pages` branch** to host the appcast:

```bash
git checkout --orphan gh-pages
git rm -rf .
echo "RuEnSync appcast" > README.md
git add README.md
git commit -m "init gh-pages"
git push origin gh-pages
git checkout main
```

**5. Enable GitHub Pages** — _Settings → Pages → Source: `gh-pages` branch,
`/` root_. The URL will be `https://alexey1312.github.io/ruen-sync-mac/`.
`release.yml` writes `appcast.xml` into that branch on every release.

Without these steps the release still ships — the Sparkle steps in
`release.yml` are gated on `SPARKLE_PRIVATE_KEY` and silently skip when absent.
Existing installs just won't see the new version in their "Check for
Updates…" dialog until the appcast is published.
