---
description: Review a PR by number — checkout, compare against main, security audit, summarize findings, and act
args:
  - name: pr
    description: PR number (e.g. 130)
    required: true
---

Review PR #{{pr}} using this exact workflow:

## 1. Gather context

Run in parallel:
- `gh pr view {{pr}} --json title,body,headRefName,baseRefName,files,additions,deletions,author` to understand scope
- Explore `plugins/` directory structure, existing `plugin.json` schemas, `plugin.js` patterns, `icon.svg` conventions, and `docs/providers/` docs to establish the baseline of "what we usually do"
- Explore other parts of the app related to the PR and how it affects the app

## 2. Checkout & read all changed files

- `gh pr checkout {{pr}}` to get the branch locally
- Read every file in the PR diff — plugin code, tests, config, icons, docs, README changes
- Also read the equivalent files from other plugins for direct comparison

## 3. Review checklist

Compare the PR against main across these dimensions:

**Structure & conventions:**
- Does `plugin.json` match our schema? (schemaVersion, id, name, version, entry, icon, brandColor, lines)
- Does `plugin.js` use the IIFE pattern with `globalThis.__openusage_plugin = { id, probe }`?
- Does `probe(ctx)` return `{ plan, lines }` using `ctx.line.*` helpers?
- Are shared utilities used where they exist? (`ctx.util.toIso`, `ctx.util.needsRefreshByExpiry`, `ctx.util.retryOnceOnAuth`, `ctx.util.request`, etc.)
- Does `icon.svg` use `fill="currentColor"` and reasonable dimensions?
- Is error handling via thrown strings (not Error objects)?
- Are tests present with standard vitest setup and `makeCtx` from `test-helpers.js`?
- Does the README update list plugins alphabetically and maintain formatting?

**If the PR touches the plugin API (`src-tauri/src/plugin_engine/`, `plugins/test-helpers.js`, `docs/plugins/`):**
- Are changes backward-compatible with existing plugins?
- Do all existing plugin tests still pass?
- Is the API surface minimal and necessary?

**Security:**
- No secrets, API keys, or credentials committed (flag client IDs/secrets with user)
- File system writes scoped only to the tool's own config files
- No arbitrary code execution paths
- No network calls to unexpected destinations
- No exfiltration of user data beyond what's needed
- Dependencies: any new ones? Are they legit (recent releases, known maintainers)?

## 4. Classify findings

Group every finding by severity:
- **Blocker**: Security vulnerability, data loss risk, breaks existing plugins, or fundamentally wrong approach
- **High**: Diverges from established patterns in ways that will cause maintenance burden or bugs
- **Medium**: Convention mismatches, minor inconsistencies, could-be-better code
- **Low**: Nits, style, optional improvements

## 5. Present summary & options

Show the user a clear summary table of findings by severity, then offer exactly three options:

**Option 1 — Close PR**: Only if there are Blocker-level security issues that aren't normal for our codebase, or the PR is intentionally harmful/spam. Explain why.

**Option 2 — Comment with feedback**: Post a concise review comment on the PR using `gh pr review {{pr}} --comment`. Write in simple, friendly language (like explaining to a 5th grader). Lead with what's good, then list what needs fixing before merge. No jargon. Keep it short — one short paragraph of praise, then a numbered list of fixes. When this option is used, you must submit it AFTER draft and approval with "request changes".

**Option 3 — Safe to merge**: If no Blocker/High issues exist, tell the user it's clean and ready.

Don't use any question tool. Just let the user pick which option you execute, then do it. If the user picks Option 2, follow the guidance below and preview the comment BEFORE you submit it.

After acting, `git checkout main` to return to the main branch.

## Example review comment (Option 2)

Here's the tone and format to aim for when posting feedback:

```
Hey! 👋 This is Rob's AI reviewer. Thanks for the contribution!

Clean plugin overall. Auth flow, tests, and docs all look solid. Three things to fix before merge:

1. **`toIso` conversion is non-standard** — `ctx.util.toIso(Math.floor(endDate / 1000))` manually converts ms→seconds, then `toIso` converts it back. Every other plugin passes values directly (e.g. `ctx.util.toIso(endDate)`). Since `endDate` is already unix ms, just pass it through.

2. **Use `ctx.util.needsRefreshByExpiry` instead of custom `needsRefresh`** — Claude and Cursor use the shared utility. Rolling your own JWT decode + expiry check works but diverges from the established pattern. Something like:
   ```js
   const payload = ctx.jwt.decodePayload(accessToken)
   const expiresAtMs = payload && typeof payload.exp === "number" ? payload.exp * 1000 : null
   if (ctx.util.needsRefreshByExpiry({ nowMs: Date.now(), expiresAtMs, bufferMs: TOKEN_REFRESH_THRESHOLD_MS })) { ... }
   ```

3. **README formatting** — removing Factory from "Maybe Soon" also deleted the blank line between the heading and the list. Small fix.

Everything else (plugin.json, icon.svg, error handling, test coverage, docs) looks good.
```

Key traits: lead with what's good, numbered fixes, code snippets where helpful, no jargon, friendly.
