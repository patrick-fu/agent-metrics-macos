# Sparkle 2 and GitHub Public Updates

Research note for the public beta release-contract work. This is **not** a contract. It records
what first-party Sparkle 2, GitHub Releases/Pages, and SQLite documentation say about hosting a
stable-channel appcast, signing update archives with EdDSA, and taking a consistent SQLite backup
before a schema change.

Last checked: 2026-08-17.

This note does **not** prescribe the operator runbook, does **not** generate keys, and must not be
used as a place to paste real identities, private keys, or local machine paths. The EdDSA public
key and signatures quoted below are Sparkle's **published documentation samples**, not this
project's release keys.

## Sources consulted

| Source | URL | Used for | Last checked |
| --- | --- | --- | --- |
| Sparkle documentation index | https://sparkle-project.org/documentation/ | EdDSA key generation, Keychain custody, key rotation vs Developer ID, DSA deprecation | 2026-08-17 |
| Publishing an update | https://sparkle-project.org/documentation/publishing/ | Archive formats, `sign_update` / `generate_appcast`, enclosure attributes, channels, versions, min OS / hardware | 2026-08-17 |
| Customizing Sparkle | https://sparkle-project.org/documentation/customization/ | `SUFeedURL`, `SUPublicEDKey`, automatic-check vs silent-install keys, signed-feed options, sandbox XPC flags | 2026-08-17 |
| Sandboxing guide | https://sparkle-project.org/documentation/sandboxing | XPC services are for sandboxed apps; non-sandboxed apps should not enable them | 2026-08-17 |
| GitHub: Managing releases | https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository | Draft → attach assets → publish; pre-release flag; asset delivery | 2026-08-17 |
| GitHub REST: download a release asset | https://docs.github.com/en/rest/releases/assets | Canonical browser download URL form `/releases/download/{tag}/{name}` | 2026-08-17 |
| GitHub Pages: Creating a site | https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site | Project Pages URL form `https://<owner>.github.io/<repository>/` | 2026-08-17 |
| SQLite `VACUUM` | https://sqlite.org/lang_vacuum.html | `VACUUM INTO 'filename'` creates a consistent backup file | 2026-08-17 |

Local tool presence (category only): this note did **not** run `generate_keys`, `sign_update`,
`generate_appcast`, `gh release create`, or any notarization command.

## 1. Sparkle 2 EdDSA is not Apple code signing

[fact] Sparkle 2 signs **update archives** (dmg, zip, and related formats) with **EdDSA
(ed25519)**. `./bin/generate_keys` creates a private key (default: login Keychain) and prints a
base64 public key that must be embedded as `SUPublicEDKey` in the app's Info.plist. See
[Sparkle documentation](https://sparkle-project.org/documentation/).

[fact] Sparkle's published sample public key (documentation only) is:

```text
pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=
```

The matching sample `sign_update` output on the publishing page is:

```text
sparkle:edSignature="7cLALFUHSwvEJWSkV8aMreoBe4fhRa4FncC5NoThKxwThL6FDR7hTiPJh1fo2uagnPogisnQsgFgq6mGkt2RBw==" length="1623481"
```

See [Publishing an update](https://sparkle-project.org/documentation/publishing/) and the
`generate_keys` example on [Sparkle documentation](https://sparkle-project.org/documentation/).

[fact] Apple Developer ID Application signing and notarization are a **different** trust path.
Sparkle's own install notes say Developer ID signing is what lets the system load Sparkle for
distribution; the EdDSA key is what authenticates later update archives. The two keys must not be
treated as interchangeable. See [Sparkle documentation](https://sparkle-project.org/documentation/)
and [Customizing Sparkle](https://sparkle-project.org/documentation/customization/).

[fact] DSA signatures are the legacy Sparkle scheme. New projects should use EdDSA only and must
not mix `SUPublicEDKey` with `SUPublicDSAKey` / file-based DSA keys as the long-term default. See
the EdDSA section and the "Migrating to EdDSA from DSA" pointer on
[Sparkle documentation](https://sparkle-project.org/documentation/).

[inference] A public-beta contract should treat Developer ID + notarization as the Gatekeeper
install trust, and Sparkle EdDSA as the updater-archive trust. Losing one key does not replace the
other.

## 2. Private-key custody, backup, and rotation

[fact] `generate_keys` is run **once**. The private key is saved in the login Keychain. The tool
can be run again to reprint the **public** key. Sparkle warns that keys are erased if the keychain
or system is erased, and recommends keeping them in the Keychain rather than on the machine that
hosts the product. See [Sparkle documentation](https://sparkle-project.org/documentation/).

[fact] Transfer/backup flags documented by Sparkle: `-x private-key-file` exports, `-f
private-key-file` imports. Those files are secrets. See
[Sparkle documentation](https://sparkle-project.org/documentation/).

[fact] `sign_update` / `generate_appcast` use the Keychain key by default. They can also take `-f`
for a file-based test key. `sign_update path_to_archive` prints `sparkle:edSignature` and
`length`. See [Publishing an update](https://sparkle-project.org/documentation/publishing/).

[fact] If the EdDSA private key is lost, Sparkle still allows signing **new** updates for
Developer ID-signed applications through **key rotation**: issue an update that changes **either**
the Apple code-signing certificate **or** the EdDSA keys, **but not both at once**. If
`SUVerifyUpdateBeforeExtraction` is enabled, changing EdDSA keys requires a Developer ID
code-signed disk image. See [Sparkle documentation](https://sparkle-project.org/documentation/)
(Rotating signing keys).

[inference] The private EdDSA key, any `-x` export, and any Keychain item name belong in an
offline backup / operator secret store. Only the public `SUPublicEDKey` value may enter the public
repo, and only after a real key is generated at implementation — not as a copied documentation
sample used as this project's key.

[unverified] Sparkle does not publish a mechanical "delete this appcast item and the updater will
roll the binary back" procedure. Recovery of a bad release is therefore an operator policy built
on top of "publish a higher `sparkle:version`" and "stop advertising the bad enclosure."

## 3. Appcast schema that Sparkle actually requires

[fact] An installable update item needs an `<enclosure>` with at least `url`,
`sparkle:edSignature`, `length`, and `type`. `sparkle:version` (machine/build version) and
optionally `sparkle:shortVersionString` (marketing version) belong on the item. See
[Publishing an update](https://sparkle-project.org/documentation/publishing/).

[fact] Sparkle compares the **internal / machine-readable** version:
`CFBundleVersion` in the running app versus `sparkle:version` in the appcast. That value is "not
generally suitable for formatted text or git changeset IDs." Marketing numbers go in
`CFBundleShortVersionString` / `sparkle:shortVersionString`. See
[Publishing an update](https://sparkle-project.org/documentation/publishing/) and Apple's
[`CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleversion).

[fact] Raising the required macOS version is done with `sparkle:minimumSystemVersion` as a
three-part `major.minor.patch` string (example form `10.13.0`). Sparkle 2.9 also accepts
`sparkle:hardwareRequirements` with `arm64` to require Apple silicon. See
[Publishing an update](https://sparkle-project.org/documentation/publishing/).

[fact] Default / stable-channel items have **no** `sparkle:channel` element. A
`<sparkle:channel>beta</sparkle:channel>` item is invisible to updaters that have not opted into
that channel. An updater cannot exclude the default channel. See
[Publishing an update](https://sparkle-project.org/documentation/publishing/).

[fact] Omitting `<enclosure>` (or using `<sparkle:informationalUpdate>`) makes the item a
download-link / informational update, not an in-app install. That is not a Sparkle auto-update.
See [Publishing an update](https://sparkle-project.org/documentation/publishing/).

[inference] A stable-only public beta should publish default-channel items with a complete
enclosure, a numeric `sparkle:version` that never decreases, `sparkle:shortVersionString`,
`sparkle:minimumSystemVersion` of `14.0.0`, and `sparkle:hardwareRequirements` of `arm64` once
every installed updater is Sparkle 2.9+. Until that is guaranteed, the shipped Mach-O slice set
and `LSMinimumSystemVersion` remain the hard architecture/OS gates.

## 4. Automatic checks vs silent install

[fact] `SUFeedURL` is the appcast URL and should be set in Info.plist even if later overridden.
`SUPublicEDKey` is the base64 EdDSA public key. See
[Customizing Sparkle](https://sparkle-project.org/documentation/customization/).

[fact] If `SUEnableAutomaticChecks` is **unset**, Sparkle disables automatic checks initially and
**prompts on the second launch** for permission. Setting it to `YES` enables automatic checking
(not installation) without that prompt. Setting it to `NO` disables automatic checking without
the prompt. See [Customizing Sparkle](https://sparkle-project.org/documentation/customization/).

[fact] `SUAutomaticallyUpdate` defaults to `NO`. `YES` means Sparkle tries to **download and
install silently** in the background. Authorization can still block silent install. This is a
different switch from automatic *checking*. See
[Customizing Sparkle](https://sparkle-project.org/documentation/customization/).

[fact] `SUScheduledCheckInterval` defaults to 86400 seconds (1 day) and has a documented minimum
bound of 1 hour. See [Customizing Sparkle](https://sparkle-project.org/documentation/customization/).

[inference] A product constraint of "automatic updates are required" maps cleanly onto
`SUEnableAutomaticChecks = YES`. It does **not** by itself require `SUAutomaticallyUpdate = YES`.
Silent install is a separate default and was not requested by Sparkle's own wording.

## 5. Sandbox / XPC (out of the P0 native shell unless later forced)

[fact] Sparkle's sandbox XPC settings (`SUEnableInstallerLauncherService`,
`SUEnableDownloaderService`, and related keys) are for **sandboxed** apps. The customization page
says non-sandboxed applications should not customize those settings; the sandboxing guide is the
place for the XPC layout. See [Customizing Sparkle](https://sparkle-project.org/documentation/customization/)
and [Sandboxing](https://sparkle-project.org/documentation/sandboxing).

[inference] The accepted P0 runtime is a single-process AppKit/SwiftUI modular monolith with no
helper daemon ([Choose the native runtime and persistence boundaries](https://github.com/patrick-fu/coding-agent-metrics/issues/6)).
Unless a later ticket forces App Sandbox, the public-beta updater should follow the non-sandboxed
Developer ID path and leave Sparkle XPC services disabled.

## 6. GitHub Releases are a good asset host; they are not a stable feed

[fact] GitHub Releases can be created as **drafts**, receive binary attachments, and later be
published. Collaborators with write access can create, edit, and delete releases. GitHub
recommends drafting first, attaching all assets, then publishing — especially if immutable
releases are enabled. A release may be marked as a pre-release. See
[Managing releases in a repository](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

[fact] The documented browser download URL for a release asset is:

```text
https://github.com/{owner}/{repo}/releases/download/{tag}/{asset_name}
```

That URL is public only after the release is published. See
[REST API endpoints for release assets](https://docs.github.com/en/rest/releases/assets)
(`browser_download_url`).

[fact] A GitHub Pages project site is served at `https://<owner>.github.io/<repository>/`. Pages
is a static-file host, not a release-asset host. See
[Creating a GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site).

[fact] This repository already has a project Pages site at
`https://patrick-fu.github.io/coding-agent-metrics/` (public Pages metadata: source branch
`prototype/compact-popover`, site path `/`). That site currently hosts a compact-popover
prototype, not an appcast.

[inference] Per-tag `/releases/download/<tag>/…` URLs are the right place for a **DMG**. They are
the wrong place for the **feed itself**, because every new tag would change the feed URL and
already-shipped apps would keep polling the old one. The feed URL embedded as `SUFeedURL` must be
stable. A dedicated Pages path such as `/updates/appcast.xml` satisfies that. How Pages is later
wired (keep the current source branch and add `updates/`, or point Pages at a dedicated updates
source) is a release-day operator choice; both can implement the same public URL.

[inference] Publishing the appcast **before** the referenced Release is public advertises a 404
enclosure. Draft assets are not a public download. The enclosure URL must be a live public HTTPS
URL at the moment the appcast is published.

## 7. SQLite backup before schema change

[fact] SQLite's `VACUUM INTO 'filename'` creates a new database file that is a vacuumed copy of
the current database — a consistent backup file, not an in-place compact. See
[SQLite VACUUM](https://sqlite.org/lang_vacuum.html).

[fact] The accepted native runtime already requires a local backup before any non-trivial
migration, and keeps parser semantic versions separate from DB schema versions
([Choose the native runtime and persistence boundaries](https://github.com/patrick-fu/coding-agent-metrics/issues/6)).

[fact] The accepted retention policy keeps raw Usage Facts until a capacity ceiling, uses
`VACUUM INTO` before schema changes, and defines Reset Data as a wipe of all App-owned telemetry
including migration backups, while schema metadata and non-telemetry preferences stay
([Measure SQLite growth and set retention](https://github.com/patrick-fu/coding-agent-metrics/issues/10)).

[inference] A public-beta updater that ships a schema bump must take a `VACUUM INTO` backup first,
migrate forward only, and fail closed if an older binary opens a newer schema. Sparkle has no
database rollback primitive.

## 8. What this note deliberately does not do

[fact] This file is research, not a release contract, not a GitHub Actions workflow, and not a
key-generation run. No Sparkle private key was created. No GitHub Release or Pages file was
modified.

[unverified] Exact `generate_appcast` CLI flags beyond those named on the publishing page, and
the precise XML namespace URI Sparkle emits, should be re-checked against the Sparkle
distribution that implementation pins. The contract can require the documented enclosure
attributes without pinning an unquoted namespace string.
