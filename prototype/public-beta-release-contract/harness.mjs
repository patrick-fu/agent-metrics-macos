#!/usr/bin/env node
// Throwaway public-beta release-contract checker.
// Synthetic fixtures only. No Apple / GitHub / Keychain calls.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const fixturesDir = join(here, "fixtures");

const failures = [];
const passes = [];

function pass(name) {
  passes.push(name);
}

function fail(name, detail) {
  failures.push(`${name}: ${detail}`);
}

function read(path) {
  return readFileSync(path, "utf8");
}

function parseItems(xml) {
  const items = [];
  const itemRe = /<item\b[\s\S]*?<\/item>/gi;
  let match;
  while ((match = itemRe.exec(xml))) {
    const block = match[0];
    const pick = (re) => {
      const found = block.match(re);
      return found ? found[1].trim() : "";
    };
    const enclosure = block.match(/<enclosure\b([^>]*)\/?>/i);
    const attrs = enclosure ? enclosure[1] : "";
    const attr = (name) => {
      const found = attrs.match(new RegExp(`${name}\\s*=\\s*"([^"]*)"`, "i"));
      return found ? found[1] : "";
    };
    items.push({
      version: pick(/<sparkle:version>([^<]*)<\/sparkle:version>/i),
      shortVersion: pick(
        /<sparkle:shortVersionString>([^<]*)<\/sparkle:shortVersionString>/i,
      ),
      minOs: pick(
        /<sparkle:minimumSystemVersion>([^<]*)<\/sparkle:minimumSystemVersion>/i,
      ),
      channel: pick(/<sparkle:channel>([^<]*)<\/sparkle:channel>/i),
      url: attr("url"),
      signature: attr("sparkle:edSignature"),
      length: attr("length"),
      raw: block,
    });
  }
  return items;
}

function itemProblems(item, { allowChannel = false } = {}) {
  const problems = [];
  if (!item.url) problems.push("missing enclosure url");
  else if (!item.url.startsWith("https://")) {
    problems.push(`enclosure url is not https: ${item.url}`);
  }
  if (!item.signature) problems.push("missing sparkle:edSignature");
  if (!item.length) problems.push("missing length");
  else if (!/^[1-9][0-9]*$/.test(item.length)) {
    problems.push(`length must be a positive integer, got ${item.length}`);
  }
  if (!item.version) problems.push("missing sparkle:version");
  else if (!/^[1-9][0-9]*$/.test(item.version)) {
    problems.push(`sparkle:version must be a positive integer, got ${item.version}`);
  }
  if (!item.shortVersion) problems.push("missing sparkle:shortVersionString");
  if (!item.minOs) problems.push("missing sparkle:minimumSystemVersion");
  if (!allowChannel && item.channel) {
    problems.push(`stable channel must not set sparkle:channel (${item.channel})`);
  }
  return problems;
}

function versionSetProblems(items) {
  const seen = [];
  for (const item of items) {
    if (!/^[1-9][0-9]*$/.test(item.version)) continue;
    seen.push(Number(item.version));
  }
  const unique = new Set(seen);
  if (unique.size !== seen.length) {
    return "sparkle:version repeats; each advertised build must be unique";
  }
  return "";
}

function checkAppcastFixture(name, { expectFail, reason } = {}) {
  const xml = read(join(fixturesDir, name));
  const items = parseItems(xml);
  const problems = [];
  if (items.length === 0) problems.push("no <item> elements");
  for (const [index, item] of items.entries()) {
    for (const problem of itemProblems(item)) {
      problems.push(`item[${index}] ${problem}`);
    }
  }
  const versionProblem = versionSetProblems(items);
  if (versionProblem) problems.push(versionProblem);
  if (expectFail) {
    if (problems.length === 0) {
      fail(name, `expected to fail (${reason}) but passed`);
    } else if (!problems.some((problem) => problem.toLowerCase().includes(reason))) {
      fail(name, `failed, but not for ${reason}: ${problems.join("; ")}`);
    } else {
      pass(`${name} rejected (${reason})`);
    }
    return;
  }
  if (problems.length > 0) fail(name, problems.join("; "));
  else pass(`${name} schema ok (${items.length} item(s))`);
}

const STAGE_ORDER = [
  "local-tests",
  "sign",
  "verify-signature",
  "notarize",
  "staple",
  "gatekeeper",
  "sparkle-sign",
  "github-release",
  "appcast-public",
];

const PASS_STATUS = {
  "local-tests": new Set(["pass"]),
  sign: new Set(["pass"]),
  "verify-signature": new Set(["pass"]),
  notarize: new Set(["Accepted"]),
  staple: new Set(["pass"]),
  gatekeeper: new Set(["pass"]),
  "sparkle-sign": new Set(["pass"]),
  "github-release": new Set(["published"]),
  "appcast-public": new Set(["published"]),
};

function pipelineProblems(doc) {
  const stages = Array.isArray(doc.stages) ? doc.stages : [];
  const byName = new Map(stages.map((stage) => [stage.name, stage]));
  const problems = [];
  if (
    Number.isInteger(doc.previousPublicBuild) &&
    Number.isInteger(doc.advertisedBuild) &&
    doc.advertisedBuild <= doc.previousPublicBuild
  ) {
    problems.push(
      `advertised build ${doc.advertisedBuild} does not exceed previous public build ${doc.previousPublicBuild}`,
    );
  }
  for (const name of STAGE_ORDER) {
    if (!byName.has(name)) problems.push(`missing stage ${name}`);
  }
  const index = new Map(stages.map((stage, i) => [stage.name, i]));
  const appcastIndex = index.get("appcast-public");
  if (appcastIndex !== undefined) {
    const appcast = stages[appcastIndex];
    if (appcast.status === "published") {
      for (const prerequisite of STAGE_ORDER.slice(0, STAGE_ORDER.indexOf("appcast-public"))) {
        const prerequisiteIndex = index.get(prerequisite);
        if (prerequisiteIndex === undefined) continue;
        if (prerequisiteIndex > appcastIndex) {
          problems.push(`appcast-public appears before ${prerequisite}`);
        }
        const status = byName.get(prerequisite)?.status;
        if (!PASS_STATUS[prerequisite].has(status)) {
          problems.push(
            `appcast-public published while ${prerequisite} is ${status ?? "missing"}`,
          );
        }
      }
    }
  }
  if (byName.get("github-release")?.status === "published") {
    const notarize = byName.get("notarize")?.status;
    if (notarize && notarize !== "Accepted") {
      problems.push(`github-release published while notarize is ${notarize}`);
    }
  }
  return problems;
}

function checkPipelineFixture(name, { expectFail, reason } = {}) {
  const doc = JSON.parse(read(join(fixturesDir, name)));
  const problems = pipelineProblems(doc);
  if (expectFail) {
    if (problems.length === 0) {
      fail(name, `expected to fail (${reason}) but passed`);
    } else if (!problems.some((problem) => problem.toLowerCase().includes(reason))) {
      fail(name, `failed, but not for ${reason}: ${problems.join("; ")}`);
    } else {
      pass(`${name} rejected (${reason})`);
    }
    return;
  }
  if (problems.length > 0) fail(name, problems.join("; "));
  else pass(`${name} order ok`);
}

const PRIVACY_RULES = [
  { name: "absolute home path", re: /\/Users\/[A-Za-z0-9._-]+/ },
  { name: "email address", re: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/ },
  { name: "private key block", re: /BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY/ },
  {
    name: "identity dump",
    re: /Team ID\s*[:=]\s*[A-Z0-9]{10}\b|Developer ID Application: [A-Za-z].+\([A-Z0-9]{10}\)/,
  },
  {
    name: "notary profile assignment",
    re: /--keychain-profile\s+(?!PROFILE\b|<[^>]+>|"<[^>]+>")["']?[^\s"']+/,
  },
];

function privacyHits(text) {
  const hits = [];
  for (const rule of PRIVACY_RULES) {
    if (rule.re.test(text)) hits.push(rule.name);
  }
  return hits;
}

function checkPrivacyFixture(name, { expectFail } = {}) {
  const hits = privacyHits(read(join(fixturesDir, name)));
  if (expectFail) {
    if (hits.length === 0) fail(name, "expected privacy hits but none found");
    else pass(`${name} rejected (${hits.join(", ")})`);
    return;
  }
  if (hits.length > 0) fail(name, hits.join(", "));
  else pass(`${name} clean`);
}

function walkPublicFiles(dir, acc = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === ".git" || entry === "node_modules") continue;
    const path = join(dir, entry);
    const st = statSync(path);
    if (st.isDirectory()) walkPublicFiles(path, acc);
    else if (/\.(md|xml|json|mjs|txt)$/i.test(entry)) acc.push(path);
  }
  return acc;
}

function checkPublicTree() {
  const roots = [
    join(repoRoot, "docs/release"),
    join(repoRoot, "docs/research/apple-direct-distribution.md"),
    join(repoRoot, "docs/research/sparkle2-github-updates.md"),
    join(here, "README.md"),
    join(here, "harness.mjs"),
  ];
  const files = [];
  for (const root of roots) {
    const st = statSync(root);
    if (st.isDirectory()) walkPublicFiles(root, files);
    else files.push(root);
  }
  for (const file of files) {
    const rel = relative(repoRoot, file);
    const hits = privacyHits(read(file));
    if (hits.length > 0) fail(`public ${rel}`, hits.join(", "));
    else pass(`public ${rel} clean`);
  }
}

checkAppcastFixture("appcast.valid.xml");
checkAppcastFixture("appcast.missing-signature.xml", {
  expectFail: true,
  reason: "edsignature",
});
checkAppcastFixture("appcast.bad-length.xml", {
  expectFail: true,
  reason: "length",
});
checkAppcastFixture("appcast.insecure-url.xml", {
  expectFail: true,
  reason: "https",
});
checkAppcastFixture("appcast.downgrade.xml", {
  expectFail: true,
  reason: "repeats",
});
checkAppcastFixture("appcast.beta-channel.xml", {
  expectFail: true,
  reason: "channel",
});

checkPipelineFixture("pipeline.valid.json");
checkPipelineFixture("pipeline.appcast-before-notarize.json", {
  expectFail: true,
  reason: "before notarize",
});
checkPipelineFixture("pipeline.appcast-before-release.json", {
  expectFail: true,
  reason: "github-release",
});
checkPipelineFixture("pipeline.notarize-invalid.json", {
  expectFail: true,
  reason: "notarize is invalid",
});
checkPipelineFixture("pipeline.version-downgrade.json", {
  expectFail: true,
  reason: "does not exceed previous public build",
});

checkPrivacyFixture("privacy-ok.md");
checkPrivacyFixture("privacy-leak.md", { expectFail: true });
checkPublicTree();

const summary = `${passes.length} passed, ${failures.length} failed`;
if (failures.length > 0) {
  console.error(summary);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log(summary);
for (const item of passes) console.log(`- ${item}`);
