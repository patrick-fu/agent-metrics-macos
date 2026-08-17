# Apple Direct Distribution (macOS Public Beta)

Research note for the public beta release-contract work. This is **not** a contract. It records
what Apple first-party documentation and official man pages say about distributing a macOS app
**outside the Mac App Store** (Developer ID signing, Hardened Runtime, notarization, stapling,
Gatekeeper assessment, version/build keys, and failure modes).

Last checked: 2026-08-17.

This note does **not** prescribe a release workflow, does **not** invent Sparkle-specific Apple
steps, and must not be used as a place to paste real identities, logs, or local machine paths.

## Sources consulted

| Source | URL | Used for | Last checked |
| --- | --- | --- | --- |
| Notarizing macOS software before distribution | https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution | What notarization is, Gatekeeper cutoff, Developer ID outside-store scope, staple requirement, `notarytool` vs deprecated `altool` | 2026-08-17 |
| Customizing the notarization workflow | https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow | `xcrun notarytool` submit/wait/info/log, zip/dmg/pkg upload, `codesign` flags for notarization, stapler after Accepted | 2026-08-17 |
| Resolving common notarization issues | https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues | Reject classes, inside-out nested signing, `get-task-allow`, empty `issues` still Invalid | 2026-08-17 |
| Creating distribution-signed code for the Mac | https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac | Developer ID Application vs Installer vs Mac App Store identities; deep / inside-out signing | 2026-08-17 |
| Packaging Mac software for distribution | https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution | Signed app on signed DMG; zip cannot be stapled; staple the shipped container | 2026-08-17 |
| Hardened Runtime | https://developer.apple.com/documentation/security/hardened_runtime | Runtime policy, `--options runtime`, exception entitlements | 2026-08-17 |
| TN2206 macOS Code Signing In Depth | https://developer.apple.com/library/archive/technotes/tn2206/_index.html | Nested-code locations, inside-out order, `--deep` caveats, verify/assess commands | 2026-08-17 |
| Placing content in a bundle | https://developer.apple.com/documentation/bundleresources/placing_content_in_a_bundle | Legal locations for frameworks, XPC, helpers, plug-ins | 2026-08-17 |
| Embedding nonstandard code structures in a bundle | https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle | Extra helpers/frameworks still must be signed and placed legally | 2026-08-17 |
| Developer ID | https://developer.apple.com/developer-id/ | Outside-store identity program used by Gatekeeper | 2026-08-17 |
| Developer ID support | https://developer.apple.com/support/developer-id/ | Developer ID Application / Installer certificate roles | 2026-08-17 |
| Certificates overview | https://developer.apple.com/help/account/create-certificates/certificates-overview | Certificate types; identities stay in the account/keychain, not the repo | 2026-08-17 |
| Safely open apps on your Mac | https://support.apple.com/en-us/HT202491 | Quarantine + Gatekeeper user-facing behavior | 2026-08-17 |
| `CFBundleShortVersionString` | https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleshortversionstring | Marketing / user-visible version | 2026-08-17 |
| `CFBundleVersion` | https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleversion | Build version; must increase per distinct build | 2026-08-17 |
| `LSMinimumSystemVersion` | https://developer.apple.com/documentation/bundleresources/information_property_list/lsminimumsystemversion | Lowest macOS the bundle will launch on | 2026-08-17 |
| Building a universal macOS binary | https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary | Apple silicon / Intel expressed as Mach-O slices, not a version string | 2026-08-17 |
| `codesign(1)` man page | local `man codesign` (Apple system manual) | Sign/verify options, `--deep` deprecated for signing, `runtime` flag, ad-hoc `-` | 2026-08-17 |
| `stapler(1)` man page | local `man stapler` (Apple system manual) | staple/validate, supported types, exit classes, internet required | 2026-08-17 |
| `spctl(8)` man page | local `man spctl` (Apple system manual) | `--assess`, `--type execute\|install\|open`, exit codes | 2026-08-17 |
| `xcrun notarytool --help` and subcommand help | local Apple developer tool help | submit/info/wait/history/log, credential flags, `--wait` | 2026-08-17 |

Local tool presence (category only; no identities, no machine paths): `codesign`, `stapler`, and `spctl` exist as system tools; `notarytool` is invoked via `xcrun notarytool`. This note did **not** run `notarytool submit`, `codesign --sign`, or any identity-listing command.

## 1. Developer ID Application signing (outside the Mac App Store)

[fact] Distributing a Mac app **outside the Mac App Store** uses the Developer ID program, not Mac App Store distribution identities. Users' Macs identify the developer from the Developer ID signature; Gatekeeper uses that signature together with notarization. See [Developer ID](https://developer.apple.com/developer-id/) and [Developer ID support](https://developer.apple.com/support/developer-id/).

[fact] There are two outside-store signing identities with different objects: **Developer ID Application** signs apps, command-line tools, libraries/frameworks, and XPC services; **Developer ID Installer** signs installer packages (`.pkg`). Mac App Store uses a different identity family (Apple Distribution / third-party Mac Developer Application). See [Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [Developer ID support](https://developer.apple.com/support/developer-id/).

[fact] Notarization is intended for Developer ID-signed software distributed outside the Mac App Store. If the product is distributed **only** through the Mac App Store, Apple says you do not notarize it (App Review already happens). See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

[fact] Apple's documented command-line signing shape for a notarizable app/tool is `codesign` with a Developer ID Application identity, a **secure timestamp**, and the Hardened Runtime option. The customizing-workflow page shows:

```text
codesign --force --timestamp --options=runtime --sign "Developer ID Application: COMPANYNAME" TARGET
```

See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow). The identity string in that example is a **form**, not a value to copy; do not put a real team name or Team ID into this repo.

[fact] `codesign -s -` (ad-hoc signing) does not use a Developer ID identity. The `codesign(1)` man page says ad-hoc signing identifies exactly one instance of code and has significant restrictions. Apple's notarization workflow says the notary service rejects unsigned or improperly signed software, including ad-hoc local signatures. See `man codesign` and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

[fact] `codesign(1)` looks up the identity in the caller's keychain search list (common name contains the identity string, or a 40-hex SHA-1 certificate hash, or an identity preference). Multiple partial matches fail. This is why public docs/issues must describe the **certificate kind** (Developer ID Application) and never a serial, hash, or local keychain path. See `man codesign` section SIGNING IDENTITIES.

[fact] Signing is **deep in the product sense**: every nested executable must be signed. After any change to sealed content, the containing bundle must be signed again. See [Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

[inference] A public-beta desktop app that is not going through the Mac App Store should be treated as a Developer ID Application product: sign the `.app` and every nested code item with Developer ID Application, then notarize the distribution archive (usually a signed `.dmg`). A `.pkg` wrapper, if used, is a separate Developer ID Installer object.

## 2. Hardened Runtime and notarization preconditions

[fact] Hardened Runtime is a macOS security policy that restricts unsigned executable memory, library loading, debugging, and `DYLD_*` environment variables. It is enabled by the Xcode Hardened Runtime capability or by `codesign --options runtime` / `--options=runtime`. See [Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime) and `man codesign` OPTION FLAGS (`runtime`: on macOS 10.14+, opts the process into hardened runtime including runtime code-signing enforcement, library validation, hard, kill, and debugging restrictions).

[fact] Apple's notarization documentation treats Hardened Runtime as a **precondition**. Common notary failures include "The executable does not have the hardened runtime enabled." See [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues) and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

[fact] Other documented notarization preconditions for the binaries themselves:

- signed with Developer ID (not ad-hoc, not unsigned);
- signature includes a **secure timestamp** (`codesign --timestamp`);
- Hardened Runtime enabled;
- built against the 10.9 SDK or later;
- signature still valid (container not mutated after signing);
- the debug entitlement `com.apple.security.get-task-allow` must **not** be present on a distributed Developer ID build.

See [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues).

[fact] Hardened Runtime **exceptions** are entitlements such as `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.disable-library-validation`, and `com.apple.security.cs.allow-dyld-environment-variables`. They weaken the policy. Apple says they can attract extra notary scrutiny and may cause rejection if they are not justified. See [Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime) and [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues).

[fact] App Sandbox is a **different** policy. It is required for Mac App Store apps; it is not required merely because a Developer ID app is notarized. See [Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime) (sandbox vs hardened runtime) and Apple's Mac App Store distribution docs contrasted in [Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

[fact] In a notarized app, `LD_LIBRARY_PATH` does not work and `DYLD_*` variables are ignored. Apple tells developers to use rpath or `dlopen` with a full path. See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

[fact] From macOS 10.15 onward, Gatekeeper blocks software that is not notarized. Notarization is compatible back to macOS 10.9. Before 10.14.5, Gatekeeper did not require Developer ID + notarization in the modern sense. See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

[fact] Notarization is **not** App Review. Apple scans for malicious content and signing issues and issues a ticket. Users do not need a developer account to verify a ticket. See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## 3. Nested code signing order (inside-out)

[fact] Nested code must be signed **innermost first** (inside-out). If inner content changes, the containing bundle must be re-signed. See [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues), [Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), and [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

[fact] `codesign(1)` `--deep` when **signing** is **deprecated as of macOS 13.0**. The man page warns that all signing options are applied to all nested content ("almost never what you want"), that only well-structured macOS bundles with a `Contents` folder qualify, and that code outside the listed directories is **not** signed by `--deep`. Apple/TN2206 likewise warn that `--deep` signing has caveats; prefer explicitly signing each nested item, then the container. `--deep` remains meaningful for **verification** (recursively verify nested content). See `man codesign` and [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

[fact] `codesign(1)` `--deep` only discovers nested code in these directories:

- `Contents`
- `Contents/Frameworks`
- `Contents/SharedFrameworks`
- `Contents/PlugIns`
- `Contents/Plug-ins`
- `Contents/XPCServices`
- `Contents/Helpers`
- `Contents/MacOS`
- `Contents/Library/Automator`
- `Contents/Library/Spotlight`
- `Contents/Library/LoginItems`

Code (Mach-O or bundles) outside those locations is not signed by `--deep` and is also the class of layout Gatekeeper/notary expect you **not** to hide. See `man codesign`, [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), and [Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing_content_in_a_bundle).

[fact] Documented nested-code kinds that must be signed for a typical app: bundled executables, libraries, frameworks, XPC services, helpers, plug-ins, and login items. A later mutation of a signed container (adding a resource after signing) commonly produces "The signature of the binary is invalid." See [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues) and [Embedding nonstandard code structures in a bundle](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle).

[fact] For a disk image used as the distribution vehicle: create the image, **sign the image itself** with Developer ID Application, then notarize that signed image. Nested apps inside an installer package should already be signed and notarized before the package is signed with Developer ID Installer. See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow) and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

[unverified] Apple official documentation does **not** mention Sparkle by name. There is therefore no first-party Sparkle signing recipe in this note.

[inference] Under the nested-code rules above, a Sparkle.framework, its XPC services, and any Autoupdate/Updater helpers shipped inside the `.app` are ordinary nested code: place them in bundle-legal locations, sign each Mach-O/bundle inside-out with Developer ID Application + timestamp + Hardened Runtime, then sign the outer `.app`. Do not copy third-party Sparkle wiki steps into an Apple-only contract.

## 4. `notarytool` submit flow, success/fail, public vs private log fields

[fact] Current Apple guidance is `xcrun notarytool`. `altool` is deprecated and no longer accepts new submissions; already-notarized apps keep their tickets. See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

[fact] Official `notarytool` subcommands (from `xcrun notarytool --help`): `store-credentials`, `submit`, `info`, `wait`, `history`, `log`.

[fact] Uploadable archive types are zip, dmg, or pkg. A bare `.app` is **not** submitted directly; zip it first (`ditto -c -k --keepParent`). Upload the app **and** any installer package / disk image you actually ship. See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow) and [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

[fact] Authentication options on `submit` / `info` / `wait` / `log` (from subcommand `--help`) include:

- keychain profile created by `store-credentials` (`--keychain-profile`);
- Apple ID + app-specific password + Team ID;
- App Store Connect API key (`--key` path to the private key, `--key-id`, `--issuer`).

All of those values are private. See `xcrun notarytool submit --help` and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow). Apple requires an **app-specific password**, not the Apple ID password.

[fact] Synchronous completion: `xcrun notarytool submit ARCHIVE --keychain-profile PROFILE --wait`. `--wait` defaults to false; `--timeout` can bound polling. Without `--wait`, poll with `notarytool info SUBMISSION-ID` or `notarytool wait SUBMISSION-ID`. `history` lists previous submissions for the team. See `xcrun notarytool submit --help`, `wait --help`, and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

[fact] After processing completes, `xcrun notarytool log SUBMISSION-ID` retrieves pretty-printed JSON. The log describes an `issues` array of objects with `message`, `path`, and `docUrl`. An **empty** `issues` array does **not** always mean success. See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow) and [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues).

[fact] Apple documents submission `status` values **Accepted**, **Invalid**, and **Rejected**. Accepted means the ticket was issued (success). Invalid/Rejected mean the software is not notarized; inspect the log. Empty `issues` with status Invalid is still a failure. See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow) and [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues).

[inference] A later release contract should treat **only** `status == Accepted` as the public success predicate, then staple. Do not treat "log downloaded" or "empty issues" as success.

[fact] Fields that are **safe to discuss in public** as generic classes: issue `message` text of the well-known reject strings Apple already publishes (for example "The binary is not signed.", "The signature does not include a secure timestamp.", "The executable does not have the hardened runtime enabled."), `docUrl` values that point at Apple documentation, and **generic** path patterns such as `AppName.app/Contents/Frameworks/...`. See [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues).

[fact] Fields / values that **must stay private** (must not enter this repo or a public issue): Apple ID / email, app-specific password, Team ID, keychain profile name actually used, API key ID / issuer / `.p8` contents, real submission UUIDs, certificate serials or hashes, local absolute paths (especially anything under a user home directory), host/device names, and the raw JSON of a real `notarytool log`. See `xcrun notarytool submit --help` (those flags exist because they are credentials) and [Certificates overview](https://developer.apple.com/help/account/create-certificates/certificates-overview).

[unverified] Apple does not publish a machine-stable public JSON schema document for every `notarytool log` / `info` field beyond the descriptions on the notarization pages and local `--help`. A contract writer should bind to the documented `status` / `issues` fields and treat unknown keys as opaque.

## 5. `stapler` stapling: `.app` vs `.dmg`, why public release must staple

[fact] After Apple-side notarization succeeds, staple the ticket so Gatekeeper can find it even offline. Apple provides a public ticket-ingestion service, but still tells developers to staple before distribution. See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) (service URL `https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup`) and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

[fact] `stapler(1)` attaches tickets for notarized executables to **app bundles, disk images, and packages**. Commands:

```text
stapler staple path
stapler validate path
```

Success produces no output and exit status 0 (classic UNIX). `--verbose` adds diagnostics. See `man stapler`.

[fact] Supported file formats: UDIF disk images, signed flat installer packages, and certain code-signed executable bundles such as `.app`. Unsigned packages/bundles are an error. Zip archives are **not** a supported staple target. See `man stapler` and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

[fact] How this maps to the two common public-beta vehicles:

- **Ship a `.dmg`:** sign the app, put it on a Developer ID-signed disk image, notarize the disk image, staple the **disk image**. The exported, notarized, stapled DMG can be distributed as-is.
- **Ship a zip of the `.app`:** the zip is not signed and cannot be stapled. Notarize the zip (notary scans the contents), then **unzip and staple the `.app`**. Redistribute that stapled app (re-zipping after staple is a packaging choice; the staple lives on the app).

See [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

[fact] Why a public release must staple: Gatekeeper can fetch a ticket online if needed, but stapling makes verification work **offline** and removes first-launch dependence on the ticket-lookup service. `stapler(1)` states that stapling "enables Gatekeeper to verify the ticket offline" and that the utility must be applied before distributing command-line-built products. See `man stapler` and [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

[fact] Stapling does not replace signing or notarization. It only attaches a ticket that notarization already produced. Re-signing a stapled container **invalidates** the stapled ticket; staple again after any re-sign. `stapler` requires internet access to retrieve tickets when stapling or validating. See `man stapler`.

[fact] Documented `stapler` failure classes (`man stapler` DIAGNOSTICS):

- `EX_NOINPUT` — path missing, not signed, unsupported type, or (on validate) ticket missing/invalid;
- `EX_DATAERR` — ticket data invalid;
- `EX_NOPERM` — ticket revoked;
- `EX_NOHOST` — path has not been previously notarized, or the ticketing service returned an unexpected response;
- `EX_CANTCREAT` — ticket retrieved and validated but could not be written.

Also: only one path per invocation; the containing folder must be writable; a symlink at `Contents/CodeResources` must be removed before staple will function.

## 6. Gatekeeper assessment: official verification commands

[fact] Downloaded apps are quarantined (`com.apple.quarantine` extended attribute). Gatekeeper then checks the signature and, on modern macOS, notarization. See [Safely open apps on your Mac](https://support.apple.com/en-us/HT202491) and [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

[fact] `codesign --verify` checks that the code is signed, the signature is structurally/cryptographically valid, and sealed components are unaltered. It does **not** check OS policy: a verified signature may still fail Gatekeeper. See `man codesign` OPERATION ("Verification/validation do not check the signature against OS policy").

[fact] Apple-documented developer verification commands, as a set:

| Check | Command shape | What success means |
| --- | --- | --- |
| Signature integrity | `codesign --verify --verbose` (Apple workflow page); deeper: `codesign --verify --deep --strict --verbose=2` (TN2206 / distribution-signed-code) | Exit 0; UNIX-silent on success unless verbose. Nested content is fully verified only with `--deep`. |
| Display / inspect | `codesign --display --verbose=4` | Shows identity/flags; not a policy decision. |
| Online ticket presence | `codesign --verify --check-notarization` (`codesign(1)`) | Forces an online notarization-ticket check. |
| Stapled ticket | `xcrun stapler validate` / `stapler validate` | Exit 0; ticket present and matches the service. |
| System policy | `spctl --assess` (`-a`); optional `-t execute` (default) or `-t install`; `-v` for verbose | Exit 0 accepted; exit 3 is denial with no other error (`man spctl`). |

See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow), [Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), `man codesign`, `man stapler`, `man spctl`.

[fact] `spctl(8)` assessment types: `execute` (code execution; default), `install` (installer package), `open` (documents). Example in the man page: `spctl -a /Applications/Mail.app`. Exit 0 success, 1 operation failed, 2 bad arguments, 3 assessment denial, 4 deprecated operation.

[unverified] The exact modern verbose `spctl` success **string** (historically phrases such as `accepted` and `source=Developer ID` / `source=Notarized Developer ID` in TN2206-era output) is OS-version dependent and is **not** pinned as a stable API in `spctl(8)`. A contract should assert: exit 0 from `spctl --assess` on a quarantined-style Developer ID + notarized build, plus `codesign --verify --deep --strict` exit 0 and `stapler validate` exit 0. Do not hard-code an English `source=` line without re-checking the target OS.

[inference] Recommended public-beta verification **set** (all three; none alone is sufficient):

1. `codesign --verify --deep --strict --verbose=2` on the `.app` (and on the `.dmg` if the image itself is signed);
2. `spctl --assess --type execute -vv` on the `.app` (use `--type install` for a `.pkg`);
3. `stapler validate` on the **shipped** container (the `.dmg` if that is what users download; the `.app` if a zipped app is what was stapled).

[fact] Changing any sealed file after signing invalidates the seal; Gatekeeper then treats the product as broken/unsigned nested code even if the outer bundle "looks" signed. See [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) and [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues).

## 7. Apple silicon and minimum OS in the bundle

[fact] The lowest macOS version the bundle will launch on is `LSMinimumSystemVersion` in Info.plist: a string of period-separated integers (example form `13.0`). See [`LSMinimumSystemVersion`](https://developer.apple.com/documentation/bundleresources/information_property_list/lsminimumsystemversion).

[fact] CPU architecture is expressed primarily by **Mach-O slices** (`arm64`, `x86_64`, or a universal/fat binary containing both), not by a marketing version string. `codesign(1)` signs all architectures in a universal Mach-O and, on verify, defaults to `--all-architectures`. See [Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary) and `man codesign`.

[unverified] This research pass did not fully quote the Info.plist pages for `LSArchitecturePriority` and `LSRequiresNativeExecution`. Do not invent a single "Apple silicon required" Info.plist key. If a later contract needs to *require* Apple silicon, bind it to the shipped Mach-O slice set (arm64-only vs universal) and to `LSMinimumSystemVersion`, and re-open those two keys from Apple’s Information Property List reference before treating them as requirements.

[fact] iOS-oriented keys such as `LSRequiresIPhoneOS` are not the macOS minimum-OS switch. Use `LSMinimumSystemVersion` for Mac. See [`LSMinimumSystemVersion`](https://developer.apple.com/documentation/bundleresources/information_property_list/lsminimumsystemversion).

## 8. Version / build: `CFBundleShortVersionString` vs `CFBundleVersion`

[fact] `CFBundleShortVersionString` is the **user-visible** (marketing / short) version string. Apple documents it as three period-separated integers (example form `1.2.3`). See [`CFBundleShortVersionString`](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleshortversionstring).

[fact] `CFBundleVersion` is the **build** version. It must increment for each upload / each distinct build. It may be a monotonic integer or an `n.n.n` string. It is distinct from the short version; the system uses it to distinguish builds. See [`CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleversion).

[inference] A public-beta contract should treat short version as the human-facing beta label and build version as the strictly monotonic identifier that changes on every notarized artifact, even when the short version stays the same.

[unverified] Apple’s bundle-key pages do not, by themselves, define how a third-party auto-updater (Sparkle or otherwise) should compare those two keys. Any Sparkle appcast mapping is outside this Apple-only note.

## 9. Failure modes

### 9.1 Notarization reject / Invalid

[fact] Official reject-message classes from [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues):

- "The binary is not signed."
- "The signature does not include a secure timestamp."
- "The executable does not have the hardened runtime enabled."
- "The binary uses an SDK older than the 10.9 SDK."
- "The signature of the binary is invalid." (often: signed container mutated afterwards)
- "The executable requests the com.apple.security.get-task-allow entitlement."

[fact] Related official causes: unsigned or ad-hoc nested code; nested code in illegal bundle locations; unjustified Hardened Runtime exception entitlements; skipping inside-out re-sign after changing inner content. Status Invalid with empty `issues` is still a failure. See the same page and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

### 9.2 Staple fail

[fact] Official / man-page causes: item not yet Accepted / "has not been previously notarized" (`EX_NOHOST`); ticketing service unexpected response; unsupported type (including zip); unsigned target; ticket revoked (`EX_NOPERM`); ticket could not be written (`EX_CANTCREAT`); container re-signed after a previous staple (ticket invalidated; must staple again); no network. See `man stapler` and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

### 9.3 Gatekeeper block

[fact] On macOS 10.15+, Gatekeeper blocks software that is not notarized. It also blocks software that is not Developer ID-signed when the assessment policy requires that source. Quarantine + failed `spctl --assess` is the user-visible path (Support article: the system warns / refuses to open). A ticket that is neither stapled nor fetchable can fail the first launch offline. See [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Safely open apps on your Mac](https://support.apple.com/en-us/HT202491), and `man stapler`.

[inference] A public-beta build that is signed but not notarized, or notarized but not stapled and then opened offline, should be treated as a release-blocking Gatekeeper failure even if `codesign --verify` passed.

### 9.4 Unsigned nested code

[fact] Unsigned or illegally placed nested code produces notary Invalid, fails `codesign --verify --deep --strict`, and can fail Gatekeeper even when the outer `.app` appears signed. `--deep` signing will not save items stored outside the listed `Contents/...` locations. See [Resolving common notarization issues](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues), `man codesign`, and [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

## 10. Identity values that must not enter the public repo or issue

Describe these by **category only**. Never paste examples that look like real values.

[fact] The following are credentials, team identifiers, or machine-local secrets used by the official tools. They belong in a private keychain / CI secret store, not in git, README, or a public issue:

| Category | Why it is private | Official hook |
| --- | --- | --- |
| Apple ID / email | Account identifier for `notarytool` | `notarytool --apple-id`; customizing-workflow page |
| App-specific password | Notary authentication secret | customizing-workflow page; `notarytool --password` |
| Team ID | Team-scoped identifier | `notarytool --team-id`; identity string form on the distribution-signing page |
| Keychain profile name actually used | Names stored notary credentials | `notarytool store-credentials` / `--keychain-profile` |
| App Store Connect API key ID, Issuer ID, `.p8` / `--key` path | Alternate notary auth | `notarytool submit --help` (`--key`, `--key-id`, `--issuer`) |
| Certificate serial, SHA-1/SHA-256, `.p12`, private key | Signing identity | `man codesign` SIGNING IDENTITIES; [Certificates overview](https://developer.apple.com/help/account/create-certificates/certificates-overview) |
| Real `notarytool` submission UUID | Team-correlated handle used by `info` / `wait` / `log` | `notarytool info --help` |
| Raw `notarytool log` JSON from a real run | Contains local paths and submission correlation | customizing-workflow `log` command |
| `security find-identity` / `codesign --display` dumps | Embed team/cert hashes | `man codesign` |
| Local absolute paths, user home, device/host names | Identify a machine or person | any tool `--verbose` output |

[inference] A public issue or contract may say "Developer ID Application identity held in CI" or "notary credentials via a keychain profile whose name lives only in the secret store." It may quote Apple’s **generic** reject strings. It must not quote a real log, a real identity line, or a real absolute path.

[fact] Revoking or replacing a Developer ID certificate is a security-sensitive account operation, not a git operation. See [Developer ID support](https://developer.apple.com/support/developer-id/) and [Certificates overview](https://developer.apple.com/help/account/create-certificates/certificates-overview).

## 11. What this note deliberately does not do

[fact] This file is research, not a release contract, not a GitHub Actions workflow, and not a signing run. No `notarytool submit` and no `codesign --sign` were invoked while writing it.

[unverified] Anything about Electron/Tauri/Sparkle packaging layouts, DMG window layout, auto-update ed25519 keys, or GitHub Release asset naming is outside Apple first-party documentation and is out of scope here.
