# Pages deployment

The Pages site is built locally from committed `main`; there is no CI deployment. The source is `website/`, and `website/site-manifest.txt` is the sole allowlist for publishable site files. `scripts/build-site.sh` derives the displayed version, build, and download URL from the newest item in `website/updates/appcast.xml`.

## Local review

Build into an empty temporary directory, inspect it, and run the contract test:

```sh
site_output="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-site.XXXXXX")"
scripts/build-site.sh "$site_output"
open "$site_output/index.html"
swift test --filter PagesSiteContractTests
```

The appcast is the canonical production feed. Preserve its signed history and do not add an enclosure for an unpublished build. Do not hardcode a future version in the site templates: the build renders placeholders from the newest feed item.

The site references `assets/og-image.png` for social previews. Before publishing, provide a real 1200×630 landscape image at that path, add it to `website/site-manifest.txt`, and verify it is not a portrait app screenshot presented as an OG card.

## Staged deployment

Deployment needs a clean local checkout of the legacy `patrick-fu/coding-agent-metrics` repository with its local `gh-pages` branch. The script checks both repository origins, requires committed website changes, creates temporary worktrees, and stages the primary website and legacy appcast separately:

```sh
scripts/deploy-pages.sh --legacy-repo PATH
```

Review both reported diffs. To publish, run:

```sh
scripts/deploy-pages.sh --legacy-repo PATH --publish
```

On `--publish`, the script first validates the entire built appcast as the production updater
contract: every item has a positive, unique, strictly descending build; an HTTPS enclosure; and a
non-empty EdDSA signature. A stable production item omits `sparkle:channel` (or leaves it empty); any
named channel, including `beta`, is rejected. It then anonymously downloads only the newest enclosure
and requires HTTPS, one enclosure, a positive declared length, a matching
`AgentMetrics-<version>.dmg` final filename, and matching downloaded byte lengths. Only after both
checks succeed does it push the primary Pages branch, then the legacy feed branch.

The two pushes are deliberately **not** an atomic transaction. If the primary push succeeds and the
legacy push fails, stop: do not announce the release or claim the feeds are synchronized. Inspect both
remote `gh-pages` HEADs and the deployed appcast hashes, repair the failed side, retry the deployment,
and finally verify matching public appcast hashes from both Pages hosts before promotion.

For an already-built artifact, run the same release check directly:

```sh
scripts/deploy-pages.sh --preflight-site PATH
```

This workflow does not sign, notarize, create releases, or modify the appcast. Those release gates remain manual.
