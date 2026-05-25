#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const VERSION_RE = /^\d+\.\d+\.\d+$/;

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

const version = process.argv[2];
if (!version) {
  fail("missing version argument. Usage: bun run ccusage:bump -- <x.y.z>");
}
if (!VERSION_RE.test(version)) {
  fail(`invalid version "${version}", expected x.y.z`);
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");

const hostApiPath = path.join(repoRoot, "src-tauri/src/plugin_engine/host_api.rs");
const docsPath = path.join(repoRoot, "docs/plugins/api.md");

function replaceOnce(content, regex, replacement, missingMessage) {
  if (!regex.test(content)) {
    fail(missingMessage);
  }
  return content.replace(regex, replacement);
}

const hostApiSource = readFileSync(hostApiPath, "utf8");
const currentVersionMatch = hostApiSource.match(
  /const CCUSAGE_VERSION: &str = "(\d+\.\d+\.\d+)";/,
);
if (!currentVersionMatch) {
  fail("could not find CCUSAGE_VERSION constant in host_api.rs");
}
const currentVersion = currentVersionMatch[1];
const updatedHostApiSource = replaceOnce(
  hostApiSource,
  /const CCUSAGE_VERSION: &str = "\d+\.\d+\.\d+";/,
  `const CCUSAGE_VERSION: &str = "${version}";`,
  "could not find CCUSAGE_VERSION constant in host_api.rs",
);
writeFileSync(hostApiPath, updatedHostApiSource);

const docsSource = readFileSync(docsPath, "utf8");
const docsCcusageVersionRegex = new RegExp(
  `\\bccusage@${currentVersion.replaceAll(".", "\\.")}`,
  "g",
);
if (!docsCcusageVersionRegex.test(docsSource)) {
  fail("could not find ccusage pin in docs/plugins/api.md");
}
docsCcusageVersionRegex.lastIndex = 0;
const docsAfterCcusage = docsSource.replace(
  docsCcusageVersionRegex,
  `ccusage@${version}`,
);
writeFileSync(docsPath, docsAfterCcusage);

console.log(`Updated ccusage version to ${version}`);
console.log(`- ${path.relative(repoRoot, hostApiPath)}`);
console.log(`- ${path.relative(repoRoot, docsPath)}`);
