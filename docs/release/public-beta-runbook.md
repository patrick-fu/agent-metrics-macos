# Public-beta release runbook

This repository has no cloud release automation. The checked-in release command is a local,
credential-free synthetic dry run. It never signs, notarizes, uploads, publishes, downloads, or
updates an app.

## Local contract check

1. Run `swift test`, `swift build`, and `scripts/build-app.sh`.
2. Run `scripts/release-check.sh`. Its only mode is `--dry-run`.
3. Require `result=PASS`, all seven ordered stages, and `publication=not-attempted`.
4. Treat `production-gate=MANUAL issue=#27 reason=validate-SUPublicEDKey-locally` as the accurate
   current state: the production key is configured, but #27 must still validate it locally. A missing
   or invalid key remains `BLOCKED`; a present key never means automatic readiness. Do not copy key
   material into output.

The dry run uses only `Fixtures/release/public-beta`. Its inspection and appcast use the same reserved
`.invalid` URL and `AgentMetrics-<version>.dmg` filename, while all signing/notarization/public-download
observations are synthetic booleans. The checker never accesses the URL. Passing proves metadata and
ordering only, not Apple trust, a cryptographic signature, or network reachability.

The public product and DMG are named **Agent Metrics** / `AgentMetrics-<short-version>.dmg`. The
reverse-DNS identity remains `dev.codingagentmetrics.app`, internal Swift modules and executable names
may remain `CodingAgentMetrics*`, and the Sparkle public key is frozen. These technical identifiers
preserve installed-data ownership and updater trust. The production feed remains
`https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml`; its enclosure must point to
the public release in `patrick-fu/agent-metrics-macos` so old clients remain upgradeable.

### Repository migration order

1. Back up the deployed legacy Pages content and current stable appcast, including signatures and
   version/build/length evidence, before changing either repository.
2. Rename the primary repository to `patrick-fu/agent-metrics-macos`.
3. Immediately create the public `patrick-fu/coding-agent-metrics` legacy Pages repository. Reusing
   the old name sacrifices GitHub's automatic repository redirect; this is an
   intentional trade-off to keep old clients upgradeable through their frozen feed URL.
4. Deploy the backed-up feed as real XML at `updates/appcast.xml`, not an HTML redirect, from the new
   legacy repository.
5. Point every enclosure to the matching public Release asset in `agent-metrics-macos`.
6. Require an unauthenticated HTTP 200 response for the legacy feed and every enclosure before
   declaring the migration complete.

## Required manual order

Every real operation below belongs to #27 and requires an explicit maintainer action. Stop at the
first failed check. Never update the stable appcast early.

1. **Validate the app.** Build the release app locally. Verify exactly `arm64`, minimum macOS `14.0`,
   bundle identifier `dev.codingagentmetrics.app`, semantic short version, positive monotonic build,
   stable HTTPS feed, automatic checks enabled, and silent automatic installation disabled. Confirm
   the production Sparkle public-key gate separately without copying key material into logs or notes.
2. **Sign, notarize, and staple the DMG.** Run the `codesign`, Apple Notary Service, and `stapler`
   command families manually with maintainer-controlled local configuration. Require every check to
   succeed. The DMG name must be `AgentMetrics-<short-version>.dmg`; record its byte length.
3. **Create a draft release.** Manually create, but do not publish, the GitHub Release whose tag is
   `v<short-version>` and whose version/build metadata matches the app and DMG.
4. **Upload and verify the public DMG.** Manually upload the DMG to the draft, then verify the final
   intended filename and byte length through maintainer access. A draft entry, authenticated download,
   or uploaded asset alone is not public-download evidence.
5. **Publish the release.** Publish only after step 4 passes. Before this stage can complete, verify an
   unauthenticated download from the final HTTPS URL and require the filename and downloaded length to
   match the uploaded DMG. The stable appcast remains blocked until this public recheck passes.
6. **Update and publish the stable appcast.** Generate the EdDSA enclosure metadata manually. Require
   exactly one stable item, HTTPS enclosure URL, non-empty EdDSA signature metadata, monotonically
   increasing build, and exact build/short-version/minimum-OS/filename/length agreement with the
   verified public DMG. Publish Pages only after the GitHub Release is public and verified.
7. **Verify the updater.** From the last-good build, manually check the stable feed, signature
   acceptance, expected version/artifact selection, visible user approval, and successful launch of
   the updated app. Silent installation is not accepted.

### Failure stop points

- Before step 5, keep the stable feed on last-good. A maintainer may repair or replace the unpublished
  draft only after revalidating every preceding stage.
- After step 5 but before step 6, leave the stable feed on last-good. Fix the release with a higher
  build; do not advertise the failed artifact.
- After step 6, do not claim rollback by deleting or rewriting public state. Stop promotion and ship a
  higher-build roll-forward release through the complete sequence.
- Repeating a completed stage, using a lower/equal build, or observing any metadata mismatch is a hard
  failure. Reconcile public state manually before starting a new higher-build attempt.

## Last-good and roll-forward recovery

Before step 1, retain the last-good DMG, its published appcast item, version/build, byte length, and
verification record. Do not overwrite or delete that recovery asset during a new release.

For an app regression, quit the app and reinstall the retained last-good DMG only when its data-schema
compatibility is known. Removing the app bundle does not remove the telemetry store. A newer build may
have migrated that store, so this project promises no database downgrade; an older app may refuse the
newer schema. When compatibility is unknown or the stable appcast was already published, prefer a
higher-build roll-forward release.

## Reset and uninstall boundaries

Reset Data deletes all app-owned telemetry, including migration backups, observations, facts, rollups,
cursors, watermarks, source state, opaque identities, diagnostics, runtime snapshots, and app-managed
export copies. It does not uninstall the app, delete Codex or Claude source logs, delete existing
external user-saved files, or remove non-telemetry settings. Cleanup may finish later and retry.

Uninstalling the app bundle alone does not delete the telemetry store or coding-agent source logs. If
the user wants app-owned telemetry removed, complete Reset Data before uninstalling. Do not describe
uninstall as a privacy erase.

## Issue 27 human gates

#27 remains blocked until a maintainer, using locally controlled credentials and identities, completes:

- Developer ID signing, notarization, stapling, Gatekeeper, and clean supported-Mac checks;
- Sparkle EdDSA signing and an upgrade from last-good through the stable feed;
- public GitHub Release and Pages appcast verification;
- clean install, launch at login, update, uninstall, and Reset Data checks;
- privacy review of the public diagnostic path; and
- the keyboard and system VoiceOver checklist in `docs/accessibility-manual-checklist.md`.

Never paste credentials, account identifiers, signing identities, profiles, key material, tokens, raw
logs, or machine-specific paths into commands captured by the repository, release notes, or issues.
