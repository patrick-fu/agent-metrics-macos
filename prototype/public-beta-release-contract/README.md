# Public-beta release-contract checker

Throwaway local validator for [Define the public beta release contract](https://github.com/patrick-fu/coding-agent-metrics/issues/8).

This is not the app, not a release script, and not a notarization helper. It only checks
synthetic fixtures and the public Markdown/XML/JSON that this ticket added.

## Run

From the repository root, with Node 18+:

```text
node prototype/public-beta-release-contract/harness.mjs
```

Expected result: exit 0 and a pass summary. There is no network access and no Keychain access.

## What it checks

1. Appcast schema: HTTPS enclosure `url`, `sparkle:edSignature`, nonzero `length`,
   `sparkle:version`, `sparkle:shortVersionString`, `sparkle:minimumSystemVersion`.
2. Stable channel: default items must not set `sparkle:channel`.
3. Version identity: each `sparkle:version` is a unique positive integer. Newest-first
   appcasts are valid. `appcast.downgrade.xml` reuses a build number; pipeline fixtures
   may also set `previousPublicBuild` / `advertisedBuild` so a lower build cannot ship.
4. Pipeline state machine: local gates → notarize `Accepted` → staple → Gatekeeper →
   Sparkle sign → **published** GitHub Release → then public appcast.
5. Privacy scan of this ticket's public docs plus `fixtures/privacy-ok.md`.
   `fixtures/privacy-leak.md` is an expected-fail fixture.

Signatures and the public key string in fixtures are Sparkle's **documentation samples**,
not this project's release keys.

## What it refuses to do

- Call `codesign --sign`, `notarytool submit`, `generate_keys`, or `sign_update`.
- Read the Keychain or print identity values.
- Touch GitHub Releases, Pages, or Actions.
