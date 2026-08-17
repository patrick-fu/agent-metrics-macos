# Public Beta Release Contract

Status: accepted default for [Define the public beta release contract](https://github.com/patrick-fu/coding-agent-metrics/issues/8).

This file is the executable public-beta gate. It is not a release, not a GitHub Actions
workflow, and not a substitute for real Developer ID / notary / Sparkle credentials.

Companion research (official sources only):

- [Apple direct distribution](../research/apple-direct-distribution.md)
- [Sparkle 2 and GitHub updates](../research/sparkle2-github-updates.md)

Throwaway checker (synthetic fixtures only):
`prototype/public-beta-release-contract/`.

## 0. Non-negotiable product constraints

These are already accepted. This contract implements them; it does not reopen them.

| Constraint | Source |
| --- | --- |
| Public open-source GitHub repository | Map #1 destination / notes |
| Public notarized DMG; not Mac App Store | Map #1 notes |
| Apple silicon, macOS 14+ | Map #1 notes |
| Native AppKit/SwiftUI + SQLite single-writer FactStore | [Choose the native runtime and persistence boundaries](https://github.com/patrick-fu/coding-agent-metrics/issues/6) |
| Sparkle 2 stable-channel automatic updates | Map #1 notes; product constraint that auto-update must not be downgraded to a manual-only check |
| Local-only build, test, sign, notarize, appcast, upgrade/rollback verification | Map #1 out of scope: no GitHub CI, no cloud release automation |
| No product analytics or remote crash reporting | Map #1 out of scope |
| Privacy-safe diagnostics only | [Define privacy-safe diagnostics export](https://github.com/patrick-fu/coding-agent-metrics/issues/9) |
| SQLite retention / Reset Data | [Measure SQLite growth and set retention](https://github.com/patrick-fu/coding-agent-metrics/issues/10) |

## 1. Artifact topology

One public binary vehicle. Do not ship a second unsigned zip "for Sparkle."

```text
clean source checkout
        │
        ▼
   CodingAgentMetrics.app          arm64 only; LSMinimumSystemVersion 14.0
        │  Developer ID Application + timestamp + Hardened Runtime
        │  nested code signed inside-out
        ▼
   CodingAgentMetrics-<short>-<build>.dmg
        │  Developer ID-signed disk image
        │  notarized (notarytool status Accepted)
        │  stapled (stapler validate exit 0)
        │  Gatekeeper-assessed
        │  Sparkle EdDSA-signed (sign_update)
        │
        ├──────────────► GitHub Release asset (manual download + Sparkle enclosure)
        │                https://github.com/patrick-fu/coding-agent-metrics/releases/download/<tag>/<dmg>
        │
        └──────────────► Sparkle appcast item (advertisement only)
                         https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml
```

| Artifact | Public location | Role |
| --- | --- | --- |
| `.app` | Inside the DMG only | Runnable product. Never published as an unsigned folder. |
| Notarized + stapled `.dmg` | GitHub Release asset for tag `v<short>+<build>` | The only downloadable binary. Same file for the website/Release page and for Sparkle. |
| SHA-256 text | Same Release, `SHA256SUMS.txt` | Public integrity check. No identity fields. |
| Sanitized release notes | GitHub Release body + optional appcast description | User-facing changes. No paths, accounts, certs, logs, prompts, or tool output. |
| Sparkle appcast | GitHub Pages, path `/updates/appcast.xml` | Stable feed URL embedded as `SUFeedURL`. Not a per-tag Release URL. |
| Sparkle public EdDSA key | App `Info.plist` `SUPublicEDKey` (source tree, once generated) | Verifies update archives. Not a signing identity. |
| Sparkle private EdDSA key | Operator Keychain + offline backup | Never in git, issues, Pages, or Release assets. |
| Developer ID identity / notary credentials | Operator Keychain | Never in git, issues, Pages, or Release assets. |

### 1.1 Filename and tag conventions

- DMG: `CodingAgentMetrics-<CFBundleShortVersionString>-<CFBundleVersion>.dmg`
  Example form: `CodingAgentMetrics-0.1.0-1.dmg`
- Git tag: `v<CFBundleShortVersionString>+<CFBundleVersion>`
  Example form: `v0.1.0+1`
- Display name of the `.app` is an implementation detail. The stem `CodingAgentMetrics` is the
  operator-facing artifact name, not a bundle-identifier claim.

### 1.2 Bundle identifier

The bundle identifier is chosen at implementation and then **frozen**. It is not chosen by this
ticket.

Rules:

- Reverse-DNS, stable for the life of the product.
- Do not encode a Team ID, person name, email, or machine name.
- Changing it after the first public beta is a new app as far as Gatekeeper, Sparkle, and the
  SQLite store location are concerned.

### 1.3 Pages wiring is a release-day seam

The public feed URL is locked:

```text
https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml
```

This ticket does **not** modify GitHub Pages. Today's Pages source is the compact-popover
prototype branch. At first real beta the operator may either:

1. add an `updates/` directory to whatever branch Pages currently publishes, without colliding
   with the popover prototype files; or
2. repoint Pages at a dedicated updates source that still serves that exact URL.

Both options implement this contract. Neither is done now.

## 2. Version, architecture, and minimum OS

| Field | Public-beta rule |
| --- | --- |
| `CFBundleShortVersionString` | Marketing `x.y.z` (three period-separated integers). First public beta starts at `0.1.0` unless a later implementation ticket picks a different marketing label. |
| `CFBundleVersion` | Strictly increasing **integer** build. Never reused. Never decreased. Changes on every notarized artifact, even when the short version does not. |
| Sparkle `sparkle:version` | Exact copy of `CFBundleVersion`. This is what Sparkle compares. |
| Sparkle `sparkle:shortVersionString` | Exact copy of `CFBundleShortVersionString`. |
| `LSMinimumSystemVersion` | `14.0` |
| Sparkle `sparkle:minimumSystemVersion` | `14.0.0` |
| Architecture | `arm64` Mach-O only. No Intel slice. |
| Sparkle `sparkle:hardwareRequirements` | `arm64` once every installed updater is Sparkle 2.9+. Until then, the arm64-only binary is the hard gate. |
| Sparkle channel | Default / stable. **No** `sparkle:channel` element. |

Parser semantic versions and DB schema versions stay separate ([issue #6](https://github.com/patrick-fu/coding-agent-metrics/issues/6)). Neither is a substitute for `CFBundleVersion`.

## 3. Trust keys: two systems, never one

| Trust system | What it signs | Public half | Private half |
| --- | --- | --- | --- |
| Apple Developer ID Application + notarization + staple | The `.app` and the shipped `.dmg` | Nothing identity-bearing. Gatekeeper sees the signature at install time. | Certificate + Keychain identity + notary credentials |
| Sparkle EdDSA (ed25519) | The update **archive** bytes (the DMG) | `SUPublicEDKey` in Info.plist | Keychain private key (`generate_keys`) |

Forbidden:

- Using the Developer ID identity as a Sparkle key, or the Sparkle key as a code-signing identity.
- Shipping DSA (`SUPublicDSAKey` / `SUPublicDSAKeyFile`) on a new product.
- Committing `generate_keys -x` output, `.p12`, `.p8`, notary profiles, or app-specific passwords.
- Embedding a documentation-sample EdDSA key as this project's real `SUPublicEDKey`.

Optional Sparkle hardening after the first public key is in users' hands:

- `SUVerifyUpdateBeforeExtraction = YES` (requires EdDSA; EdDSA rotation then needs a Developer
  ID-signed DMG — already this contract's archive type).
- `SURequireSignedFeed` is **not** required for P0. It adds feed-signing operational risk. Revisit
  only after the operator has a rehearsed key-backup drill.

Key rotation (Sparkle official rule): change **either** the Developer ID certificate **or** the
EdDSA key in one shipped update, never both. If the EdDSA private key is lost, ship a
Developer ID-signed DMG that installs a new `SUPublicEDKey`, then sign later archives with the new
key.

## 4. Sparkle runtime defaults

These Info.plist values are the public-beta updater policy.

| Key | Value | Why |
| --- | --- | --- |
| `SUFeedURL` | `https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml` | Stable HTTPS feed. |
| `SUPublicEDKey` | Real base64 public key generated at implementation | Archive authenticity. |
| `SUEnableAutomaticChecks` | `YES` | Honors "automatic updates are required" and skips the second-launch permission prompt. |
| `SUAutomaticallyUpdate` | `NO` | Check and notify. Do not silently install. Silent install was not requested. |
| `SUScheduledCheckInterval` | default `86400` | Official one-day default. |
| Sandbox XPC keys | unset / default `NO` | P0 is not sandboxed ([issue #6](https://github.com/patrick-fu/coding-agent-metrics/issues/6)). |

A Check for Updates menu item remains required so a user can force a check. It does not replace
automatic checks.

## 5. Deterministic local release stages

Every public beta walks this sequence on one operator Mac. No stage is skipped. The
pipeline is initiated and controlled by the local operator. Stage 7 must call Apple's official
Notary Service through `xcrun notarytool`. GitHub Actions, third-party hosted notarization or
appcast services, and any other cloud release automation are forbidden.

Human-only stages are marked **HUMAN**. Scriptable stages are marked **SCRIPT**.

| # | Stage | Who | Pass predicate | Stop if |
| --- | --- | --- | --- | --- |
| 1 | Clean checkout of the exact release commit | SCRIPT | `git status --porcelain` empty; `HEAD` matches the intended tag | Dirty tree, wrong commit |
| 2 | Local tests / fixture harnesses that already exist | SCRIPT | Those harnesses exit 0 | Any failing test |
| 3 | Archive / build `arm64` with `LSMinimumSystemVersion` `14.0` | SCRIPT | Single `arm64` slice; marketing + build versions written | Universal/Intel slice, wrong min OS |
| 4 | Sign nested code inside-out: helpers → frameworks → Sparkle → `.app` | SCRIPT | `codesign --force --timestamp --options=runtime --sign "Developer ID Application: …"` on each Mach-O | Ad-hoc sign, missing timestamp, missing Hardened Runtime |
| 5 | Verify signature | SCRIPT | `codesign --verify --deep --strict --verbose=2` exit 0 on the `.app` | Any nested seal failure |
| 6 | Create the Developer ID-signed DMG containing the signed `.app` | SCRIPT | DMG mounts; app name matches the replaced app; symlinks preserved | Finder-zip, followed symlinks, extra unsigned payload |
| 7 | Notarize the **DMG** | SCRIPT + **HUMAN** confirm | `xcrun notarytool submit <dmg> --keychain-profile <private> --wait` reports `status: Accepted` | `Invalid`, `Rejected`, timeout, empty-issues-but-Invalid |
| 8 | Staple the **DMG** | SCRIPT | `xcrun stapler staple <dmg>` exit 0; `xcrun stapler validate <dmg>` exit 0 | Zip staple attempt; staple before Accepted |
| 9 | Gatekeeper assessment | SCRIPT | `spctl --assess --type open --context context:primary-signature -vv <dmg>` exit 0 **and** `spctl --assess --type execute -vv <app>` exit 0 | Exit 3 / denial |
| 10 | Public hash | SCRIPT | SHA-256 of the stapled DMG written to `SHA256SUMS.txt` | Hashing a pre-staple or pre-notary file |
| 11 | Sparkle-sign the **same** DMG | SCRIPT | `sign_update` emits `sparkle:edSignature` + `length` matching the DMG byte size | Missing signature, length mismatch |
| 12 | Draft GitHub Release, attach DMG + `SHA256SUMS.txt` | SCRIPT or **HUMAN** | Release remains a **draft**; assets uploaded | Publishing at this step |
| 13 | Generate appcast **locally** (not yet public) | SCRIPT | Item has HTTPS enclosure URL pointing at `/releases/download/<tag>/…`, EdDSA, length, versions, min OS; no `sparkle:channel` | Enclosure points at a draft-only or localhost URL that will be published as the live feed |
| 14 | Privacy / notes review | **HUMAN** | Release notes and appcast contain no forbidden fields (section 10) | Any leak |
| 15 | Publish the GitHub Release | **HUMAN** | Browser can download the DMG from the `/releases/download/<tag>/` URL; HTTP 200 | Appcast already public; Release still draft |
| 16 | Publish / replace the public appcast | **HUMAN** after 15 | `SUFeedURL` serves the new item; enclosure URL still HTTP 200 | Appcast updated before step 15 |
| 17 | Post-publish verification | SCRIPT + **HUMAN** smoke | Section 7 smokes pass | Any smoke fail → section 9 recovery |

### 5.1 Ordering invariants (hard blockers)

A release is **illegal** if any of the following is true:

1. The public appcast exists or is updated before the GitHub Release is published.
2. The enclosure URL 404s or requires authentication.
3. The DMG is not Developer ID-signed, not notarized (`Accepted`), or not stapled.
4. The DMG has no Sparkle `edSignature`, or `length` ≠ byte size.
5. `CFBundleVersion` / `sparkle:version` is ≤ any previously advertised public build.
6. A GitHub Actions workflow, Pages deploy bot, third-party hosted notary/appcast service, or
   other cloud release automation performed any of stages 3–16. Apple's official Notary Service,
   invoked locally via `xcrun notarytool`, is required and is not this prohibition.
7. Any private identity value entered git, the Release body, the appcast, or a public issue.

The throwaway checker in `prototype/public-beta-release-contract/` encodes 1–5 and 7 against
synthetic fixtures. It cannot and must not talk to Apple or a real key.

### 5.2 First Sparkle-capable build

Sparkle's documented rule: after `SUPublicEDKey` is added, **ship one version** that contains the
public key before depending on signed updates (or pass `generate_appcast -s` for that last
transition archive). For this product the first public beta **is** that version: it already
embeds `SUPublicEDKey` and is itself installed from the notarized DMG. Subsequent betas are
Sparkle-signed.

## 6. SQLite backup, migration, rollback

Bound to [issue #6](https://github.com/patrick-fu/coding-agent-metrics/issues/6) and
[issue #10](https://github.com/patrick-fu/coding-agent-metrics/issues/10).

| Rule | Contract |
| --- | --- |
| Store | One local SQLite file, single writer, WAL. |
| Versions | Parser semantic version ≠ DB schema version ≠ `CFBundleVersion`. |
| Before any non-trivial schema migration | `VACUUM INTO` a migration backup next to the store. No migrate without that file. |
| Migration direction | Forward only. No down-migration in the app. |
| Migration failure | Do not open the store. Keep the backup. Surface a local recovery path. Leave last-good facts untouched. |
| Newer schema, older binary (user installed last-good DMG) | Fail closed. Do not write. Offer: keep the store and reinstall a newer app, or Reset Data. |
| Failed refresh | Keep last-good facts ([issue #10](https://github.com/patrick-fu/coding-agent-metrics/issues/10) / ingest rules). |
| Reset Data | Wipe all App-owned telemetry: facts, observations, rollups, cursors, watermarks, source state, opaque identities, diagnostics, snapshots/caches, **migration backups**, and App-managed export copies. Schema metadata and non-telemetry preferences stay. Source Codex / Claude Code logs are not modified. User-saved external files are not deleted; the confirmation copy must say so. |
| Capacity | Warn at 750 MiB or 1.5 million logical facts; hard ceiling 1 GiB or 2 million. Prune only after the hard ceiling, using the accepted ladder. |
| Sparkle vs DB | Sparkle never rolls a database back. Binary rollback is "install last-good DMG." Schema rollback is "Reset Data" or "stay on the newer app." |

## 7. Smoke tests (every public beta)

Run on Apple silicon, macOS 14+, after the Release is public. Use a clean login or a dedicated
test user when practical. Do not attach real prompts, logs, or source paths to the public tracker.

| Smoke | Steps | Pass |
| --- | --- | --- |
| Clean install | Download the published DMG over HTTPS. Open it under quarantine. Drag to `/Applications`. Launch. | Gatekeeper accepts. App launches. Empty store is schema-ready. Automatic update checks are enabled without a second-launch permission prompt. |
| Upgrade from previous beta | Install previous public beta first (or keep it). Launch. Let Sparkle see the new appcast. Install. Relaunch. | Sparkle accepts the EdDSA signature and length. `CFBundleVersion` increases. Last-good facts remain. If this beta migrates schema, a `VACUUM INTO` backup existed before the first launch of the new bits. |
| Bad-release recovery (roll-forward) | On a throwaway feed copy, advertise a higher build, then replace the feed with a still-higher good build (or remove the bad item and ship `build+1` of last-good). | Users on the bad build are offered the newer good build. Users who never fetched the bad item only see the good item. No advertised build number decreases. |
| Manual last-good reinstall | Download the previous Release DMG. Replace the app. | If schema did not bump: store opens, facts remain. If schema did bump: fail closed with recovery copy; Reset Data restores an empty schema-ready store. |
| Uninstall | Quit. Move `.app` to Trash. | Source Codex / Claude Code logs remain. App-owned store remains until the user deletes it or uses Reset Data before uninstall. Document that uninstall does not wipe the store. |
| Reset Data | Confirm the expanded wipe copy. Run it. | Telemetry, backups, and App-managed exports gone. Preferences / schema metadata remain. Source logs untouched. |
| Privacy-safe diagnostics | Export via the accepted #9 path. | Field-allowlisted manifest only. No paths, identities, prompts, bodies, credentials. Preview does not persist a file. |

VoiceOver, real AppKit timing, and the #7 resource budget remain later hardware acceptance items.
They are **not** waived by this contract; they are not re-proven here.

## 8. Acceptance matrix

Severity: **blocker** stops the release. **gate** is a release-day credential/human check that
this ticket cannot possess. **local** is a synthetic check that the throwaway harness covers.

| Gate | Command / tool | Expected result | Evidence | Severity | Visibility |
| --- | --- | --- | --- | --- | --- |
| Clean tree | `git status --porcelain` | Empty | Operator log (private) | blocker | private |
| Local tests | existing `node …/harness.mjs` plus future XCTest | Exit 0 | Private test log | blocker | private |
| Arch / min OS | `lipo -archs`, `defaults read … LSMinimumSystemVersion` | `arm64`; `14.0` | Operator note (category only) | blocker | private |
| Nested sign | `codesign --force --timestamp --options=runtime --sign "Developer ID Application: …"` | Each Mach-O signed | Do **not** save `codesign -dv` identity dumps | blocker | private |
| Signature verify | `codesign --verify --deep --strict --verbose=2` | Exit 0 | Exit status only | blocker | private |
| Notarize DMG | `xcrun notarytool submit <dmg> --keychain-profile <private> --wait` | `Accepted` | Status word only. Raw log JSON is forbidden in public trackers | blocker | private |
| Staple DMG | `xcrun stapler staple` + `stapler validate` | Exit 0 | Exit status | blocker | private |
| Gatekeeper DMG | `spctl --assess --type open --context context:primary-signature -vv` | Exit 0 | Exit status; do not pin an English `source=` string | blocker | private |
| Gatekeeper app | `spctl --assess --type execute -vv` | Exit 0 | Exit status | blocker | private |
| Hash | `shasum -a 256` | One line in `SHA256SUMS.txt` | Release asset | blocker | public |
| Sparkle sign | `./bin/sign_update <dmg>` | `sparkle:edSignature` + `length` | Attributes in appcast | blocker | public (sig + length only) |
| Appcast schema | local `generate_appcast` or hand-built XML + checker | HTTPS enclosure, versions, min OS, no channel | Public `appcast.xml` | blocker | public |
| Publish order | operator checklist + checker state machine | Release public **before** appcast | Release URL then feed URL | blocker | public |
| Version monotonic | compare to previous public `sparkle:version` | New build > old build | Appcast history | blocker | public |
| Developer ID present | capability check only (`codesign` / `notarytool --help`) | Tools exist; identity **not** printed | none | gate | forbidden to publish identity |
| Sparkle private key present | `generate_keys` reprint public half | Public key matches `SUPublicEDKey` | Public key in Info.plist | gate | public key only |
| Clean-install smoke | section 7 | Gatekeeper + launch | Private operator notes | blocker | private |
| Upgrade smoke | section 7 | Facts survive; version increases | Private operator notes | blocker | private |
| Reset Data smoke | section 7 | Wipe matches #10 | Private operator notes | blocker | private |
| Diagnostics smoke | section 7 + #9 | Allowlisted only | Optional sanitized attachment | blocker | public only if sanitized |
| Contract checker | `node prototype/public-beta-release-contract/harness.mjs` | Exit 0 | This branch | local | public fixtures |
| No CI | `git ls-files .github/workflows` | No release/notary workflow added by this ticket or later release work | git tree | blocker | public |
| Privacy scan | checker + **HUMAN** | No forbidden fields in public artifacts | Public files | blocker | public |

## 9. Failure policy

| Failure | Immediate action | Do not |
| --- | --- | --- |
| `notarytool` `Invalid` / `Rejected` | Read the log locally. Fix signing / Hardened Runtime / nested code. Resubmit a new archive. New `CFBundleVersion` if a DMG was already advertised. | Publish the DMG. Paste the raw log into an issue. Treat empty `issues` as success. |
| Staple fail | Confirm `Accepted`. Confirm the target is the DMG, not a zip. Retry `stapler staple`. | Ship an unstapled public DMG. |
| `spctl` denial | Treat as unsigned/un-notarized. Re-enter from stage 4. | Tell users to right-click override as the release path. |
| Sparkle `sign_update` fail / length mismatch | Do not write the appcast item. Check Keychain key vs `SUPublicEDKey`. | Advertise an unsigned enclosure. |
| Appcast XML error / HTTP enclosure | Keep the previous public appcast. Fix locally. | Push a broken feed. |
| Bad version already advertised | **Roll forward**: ship a higher `CFBundleVersion` containing last-good bits (or a real fix). Remove the bad item from the appcast. Keep the last-good DMG on its Release. | Decrease `sparkle:version`. Expect Sparkle to uninstall. Delete every historical Release. |
| User already installed the bad build | Offer the newer good build as a normal update. Mark `sparkle:criticalUpdate` if the bad build is unsafe. | Require every user to Reset Data unless the store is actually corrupt. |
| Schema migration fail | Leave the backup. Do not open the store. Surface recovery. | Write to a half-migrated file. Down-migrate. |
| Older app, newer schema | Fail closed. Recovery copy: reinstall newer app, or Reset Data. | Silently delete facts. |
| Lost EdDSA private key | Rotate per Sparkle: ship one Developer ID-signed DMG that installs a new `SUPublicEDKey`, then sign later archives with the new key. Do not also change the Developer ID certificate in that same update. | Commit a replacement key to git and hope. |
| Lost Developer ID identity | Account/certificate recovery outside git. Re-sign, re-notarize, re-staple, new build number. | Share a `.p12` in the repo or an issue. |
| Public leak (path, Team ID, key, log) | Delete or edit the leaked artifact. Rotate any exposed secret. Do not "fix" by committing a redacted copy of the secret. | Leave the leak in issue history unacknowledged if it is a live credential. |

Sparkle does not auto-rollback. "Rollback" in this contract means:

1. users install a **newer** build that restores last-good behavior; and/or
2. a user manually installs a previous Release DMG, accepting the fail-closed schema rule.

## 10. Public vs private vs forbidden

| Class | Examples | Where it may live |
| --- | --- | --- |
| Public | repo-relative paths; this contract; official Apple/Sparkle/GitHub URLs; DMG filename; SHA-256; `sparkle:edSignature`; `length`; `SUPublicEDKey`; sanitized release notes; appcast XML | git, issues, Pages, Releases |
| Private (operator machine / Keychain / offline backup) | Developer ID identity values, Team ID, cert serials, notary profile name/password, Apple ID, API keys, Sparkle private key and `-x` export, real `notarytool` logs, real submission UUIDs, local absolute paths, device names | never git, never issues, never Pages |
| Forbidden in any public beta artifact | prompts, source code from agent logs, tool output, raw usage logs, account/email, private URLs, full debug bundles | permanently excluded ([issue #9](https://github.com/patrick-fu/coding-agent-metrics/issues/9)) |

Capability checks (`xcrun notarytool --help`, `codesign` exists) are allowed. `security
find-identity` output is not allowed in any public file.

## 11. Local-only operator runbook seam

This ticket defines the contract. It does **not** add a release script to `main`, does **not**
create `.github/workflows`, and does **not** provision certificates.

Later implementation may add a **local** operator script that runs only the SCRIPT rows in
section 5. That script:

- must live in-repo as an optional helper, invoked by a human on a Mac;
- must read credentials from Keychain / the invoking environment, never from committed files;
- must refuse to print identity values;
- must refuse to publish Pages or a GitHub Release unless a human passes an explicit `--i-am-publishing` style confirmation;
- must refuse to update the public appcast unless the enclosure URL is already an HTTP 200 public Release asset.

**HUMAN** rows stay human: Accepted-status confirmation, privacy review, publish Release, publish
appcast, clean-user smokes.

Release-day provisioning (not this ticket):

1. Developer ID Application certificate in the operator login Keychain.
2. `notarytool store-credentials` profile, name never committed.
3. One-time `generate_keys`; public half into `SUPublicEDKey`; private half Keychain + offline backup.
4. Choose and freeze the bundle identifier.
5. Wire Pages so `SUFeedURL` serves `/updates/appcast.xml`.

## 12. Explicitly out of this contract

- Creating or running GitHub Actions, third-party hosted notarization/appcast services, or other cloud release automation. Apple's official Notary Service via `xcrun notarytool` is required at release time and is not excluded.
- Publishing a real GitHub Release or modifying Pages as part of this ticket.
- Generating a real Sparkle keypair or calling `notarytool submit`.
- Mac App Store, Intel, sandbox-required Sparkle XPC, analytics, remote crash reporting.
- Reopening #2–#7, #9, or #10.
- Choosing the bundle identifier, marketing name localization, or DMG window cosmetics.

## 13. Checker coverage

`node prototype/public-beta-release-contract/harness.mjs` must fail closed on:

- missing enclosure `url` / `sparkle:edSignature` / `length`;
- non-HTTPS enclosure;
- default-channel item that sets `sparkle:channel`;
- missing `sparkle:version`, `sparkle:shortVersionString`, or `sparkle:minimumSystemVersion`;
- decreasing integer `sparkle:version`;
- pipeline that publishes appcast before notarize / staple / Gatekeeper / Sparkle-sign / Release;
- public-text fixtures that contain home paths, emails, key blocks, or obvious identity dumps.

It must not connect to Apple, GitHub, or a Keychain item.
