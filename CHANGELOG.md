# Changelog

## 0.6.7

### New Features
- Add right-click context menu to sidebar plugin icons to remove a provider without going to settings ([#197](https://github.com/robinebers/openusage/pull/197)) by @MariosPapadakis
- Simplify menubar icon to provider + percentage ([#215](https://github.com/robinebers/openusage/pull/215)) by @robinebers
- Show deficit percentage and runs-out ETA below progress bars ([#212](https://github.com/robinebers/openusage/pull/212)) by @robinebers
- Add sqlite-first auth with keychain fallback for Cursor ([#210](https://github.com/robinebers/openusage/pull/210)) by @robinebers

### Bug Fixes
- Bump ccusage to v18.0.6 for GPT 5.3 Codex pricing fix ([#218](https://github.com/robinebers/openusage/pull/218)) by @robinebers
- Correct MiniMax API endpoint and treat usage_count as remaining prompts ([#217](https://github.com/robinebers/openusage/pull/217)) by @davidarny

### Refactor
- Split monolithic App into focused hooks and atomic stores ([#209](https://github.com/robinebers/openusage/pull/209)) by @davidarny

### Chores
- Add test cases for handling tiny deficits in formatting and display ([#216](https://github.com/robinebers/openusage/pull/216)) by @validatedev
- Compact token usage text lines (Today/Yesterday/Last 30 Days) ([#211](https://github.com/robinebers/openusage/pull/211)) by @davidarny
- Increase test coverage back to over 90% ([#207](https://github.com/robinebers/openusage/pull/207)) by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.6...v0.6.7](https://github.com/robinebers/openusage/compare/v0.6.6...v0.6.7)

- [3032c24](https://github.com/robinebers/openusage/commit/3032c24) feat: add right-click context menu to sidebar plugin icons order to be able to remove a provider without going to the settings. (#197) by @MariosPapadakis
- [a10ed10](https://github.com/robinebers/openusage/commit/a10ed10) fix: bump ccusage to v18.0.6 for GPT 5.3 Codex pricing fix (#218) by @robinebers
- [9cc62e6](https://github.com/robinebers/openusage/commit/9cc62e6) feat(tray): simplify menubar icon to provider + percentage (#215) by @robinebers
- [51dd686](https://github.com/robinebers/openusage/commit/51dd686) fix(minimax): correct API endpoint and treat usage_count as remaining prompts (#217) by @davidarny
- [b6754d3](https://github.com/robinebers/openusage/commit/b6754d3) test: add cases for handling tiny deficits in formatting and display (#216) by @validatedev
- [e28f85c](https://github.com/robinebers/openusage/commit/e28f85c) feat: show deficit percentage and runs-out ETA below progress bars (#212) by @robinebers
- [9bca9f4](https://github.com/robinebers/openusage/commit/9bca9f4) refactor(app): split monolithic App into focused hooks and atomic stores (#209) by @davidarny
- [deba467](https://github.com/robinebers/openusage/commit/deba467) feat(cursor): add sqlite-first auth with keychain fallback (#210) by @robinebers
- [0b63ade](https://github.com/robinebers/openusage/commit/0b63ade) style: compact token usage text lines (Today/Yesterday/Last 30 Days) (#211) by @davidarny
- [63c4128](https://github.com/robinebers/openusage/commit/63c4128) Increasing test coverage back to over 90% (#207) by @robinebers

## 0.6.6

### New Features
- Add local Claude/Codex usage tracking (via ccusage) ([#193](https://github.com/robinebers/openusage/pull/193)) by @validatedev
- Add MiniMax provider support ([#168](https://github.com/robinebers/openusage/pull/168)) by @davidarny

### Bug Fixes
- Show drained models + consolidate quota pools in antigravity ([#204](https://github.com/robinebers/openusage/pull/204)) by @validatedev

### Chores
- Bump version to 0.6.6 by @robinebers
- Add Factory/Droid to supported providers ([#205](https://github.com/robinebers/openusage/pull/205)) by @davidarny
- Add non-technical log capture guide by @davidarny
- Bump lucide-react from 0.564.0 to 0.575.0 ([#203](https://github.com/robinebers/openusage/pull/203)) by @app/dependabot
- Remove worktree setup configuration and update PR review feedback instructions by @robinebers
- Add worktree setup configuration by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.5...v0.6.6](https://github.com/robinebers/openusage/compare/v0.6.5...v0.6.6)

- [e425fa6](https://github.com/robinebers/openusage/commit/e425fa6) chore: bump version to 0.6.6 by @robinebers
- [a3f0c0e](https://github.com/robinebers/openusage/commit/a3f0c0e) fix(antigravity): show drained models + consolidate quota pools (#204) by @validatedev
- [e994d8b](https://github.com/robinebers/openusage/commit/e994d8b) docs: add Factory/Droid to supported providers (#205) by @davidarny
- [96d0c8b](https://github.com/robinebers/openusage/commit/96d0c8b) feat: add local Claude/Codex usage tracking (via ccusage) (#193) by @validatedev
- [c735db3](https://github.com/robinebers/openusage/commit/c735db3) chore(deps): bump lucide-react from 0.564.0 to 0.575.0 (#203) by @app/dependabot
- [cd6d7ac](https://github.com/robinebers/openusage/commit/cd6d7ac) feat: add MiniMax provider support (#168) by @davidarny
- [ebef705](https://github.com/robinebers/openusage/commit/ebef705) docs: add non-technical log capture guide by @davidarny
- [d52dc11](https://github.com/robinebers/openusage/commit/d52dc11) chore: remove worktree setup configuration and update PR review feedback instructions by @robinebers
- [41e50e3](https://github.com/robinebers/openusage/commit/41e50e3) chore: add worktree setup configuration by @robinebers

## 0.6.5

### New Features
- add Gemini provider plugin (oauth-personal, pro/flash usage) ([#189](https://github.com/robinebers/openusage/pull/189)) by @Rich627

### Bug Fixes
- improve tray icon positioning logic for macOS ([#154](https://github.com/robinebers/openusage/pull/154)) by @MuhammadAli511
- Merge pull request #188 from AdamAmr05/fix-panel-active-space by @validatedev
- Merge branch 'main' into fix-panel-active-space by @validatedev
- handle team usage without enabled flag ([#190](https://github.com/robinebers/openusage/pull/190)) by @davidarny
- Fix panel opening on the active macOS Space by @AdamAmr05
- update model versions and improve filtering logic ([#186](https://github.com/robinebers/openusage/pull/186)) by @validatedev

### Chores
- bump version to 0.6.5 by @robinebers
- update README to improve clarity and formatting by @robinebers
- update release tag management in publish workflow and clarify CONTRIBUTING.md guidelines by @robinebers
- update CONTRIBUTING.md to include maintainers and approval requirements; modify CODEOWNERS for broader review responsibility by @robinebers
- bump uuid from 1.20.0 to 1.21.0 in /src-tauri ([#179](https://github.com/robinebers/openusage/pull/179)) by @app/dependabot
- bump lucide-react from 0.563.0 to 0.564.0 ([#180](https://github.com/robinebers/openusage/pull/180)) by @app/dependabot
- remove outdated spec for next update label global refresh by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.4...v0.6.5](https://github.com/robinebers/openusage/compare/v0.6.4...v0.6.5)

- [4e35520](https://github.com/robinebers/openusage/commit/4e35520362d1cc6b1ccef57e037431b00f1e29fb) chore: bump version to 0.6.5 by @robinebers
- [d3fb059](https://github.com/robinebers/openusage/commit/d3fb059fa31bc866f1ee0fabf8fb66ad6795a982) fix(panel): improve tray icon positioning logic for macOS (#154) by @MuhammadAli511
- [59035da](https://github.com/robinebers/openusage/commit/59035dab9fa1861d28a6c7a1ce2f29b251ea2417) docs: update README to improve clarity and formatting by @robinebers
- [7dbd489](https://github.com/robinebers/openusage/commit/7dbd489aec34ea8a4054d01587c0b764ce52670e) chore: update release tag management in publish workflow and clarify CONTRIBUTING.md guidelines by @robinebers
- [1c42015](https://github.com/robinebers/openusage/commit/1c42015d4dc93306684b990e17433392a3825608) feat(gemini): add Gemini provider plugin (oauth-personal, pro/flash usage) (#189) by @Rich627
- [3997b9a](https://github.com/robinebers/openusage/commit/3997b9af0af890cb059b5f86b60966c68f7e271a) Merge pull request #188 from AdamAmr05/fix-panel-active-space by @validatedev
- [a782533](https://github.com/robinebers/openusage/commit/a78253365da4c4f411f4899e923c26d1fee3ea90) Merge branch 'main' into fix-panel-active-space by @validatedev
- [debfcd3](https://github.com/robinebers/openusage/commit/debfcd398606d7905e49dd86c0005f5ad0a3bae7) fix(cursor): handle team usage without enabled flag (#190) by @davidarny
- [fd86cde](https://github.com/robinebers/openusage/commit/fd86cde4c497f0e797e67bfbc70dfdaa5906ecd4) Fix panel opening on the active macOS Space by @AdamAmr05
- [c3305c4](https://github.com/robinebers/openusage/commit/c3305c4f7cce180ba0b6da4eb2d013a70db51a35) docs: update CONTRIBUTING.md to include maintainers and approval requirements; modify CODEOWNERS for broader review responsibility by @robinebers
- [dd0d7a4](https://github.com/robinebers/openusage/commit/dd0d7a4ef61a779e005d2f054acb4304d451ec0c) chore(deps): bump uuid from 1.20.0 to 1.21.0 in /src-tauri (#179) by @app/dependabot
- [c993fa7](https://github.com/robinebers/openusage/commit/c993fa73a3692972d773ed1f5890cde74919dc1d) chore(deps): bump lucide-react from 0.563.0 to 0.564.0 (#180) by @app/dependabot
- [12ce55f](https://github.com/robinebers/openusage/commit/12ce55f0de77de7c1eedfa51c516d3cbf5b2906d) fix: update model versions and improve filtering logic (#186) by @validatedev
- [e0036a5](https://github.com/robinebers/openusage/commit/e0036a5b34298e8583f15f5b4f000a30cccaa2f4) chore: remove outdated spec for next update label global refresh by @robinebers

## 0.6.4

### Bug Fixes
- Resolve env vars for GUI launches (fish/zsh) ([#183](https://github.com/robinebers/openusage/pull/183)) by @davidarny

### Refactor
- Remove provider_fetch_error deduplication logic by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.3...v0.6.4](https://github.com/robinebers/openusage/compare/v0.6.3...v0.6.4)

- [a7b230c](https://github.com/robinebers/openusage/commit/a7b230c) fix: resolve env vars for GUI launches (fish/zsh) (#183) by @davidarny
- [d46ce12](https://github.com/robinebers/openusage/commit/d46ce12) refactor(analytics): remove provider_fetch_error deduplication logic by @robinebers

## v0.6.3

### New Features
- Surface GPT-5.3-Codex-Spark per-model rate limits in Codex plugin ([#176](https://github.com/robinebers/openusage/pull/176)) by @robinebers

### Bug Fixes
- Reduce noisy analytics event volume with dedupe guards ([#172](https://github.com/robinebers/openusage/pull/172)) by @robinebers
- Replace `var` with `const`/`let` in Codex rate-limit loop by @robinebers

### Chores
- Bump version to 0.6.3 by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.2...v0.6.3](https://github.com/robinebers/openusage/compare/v0.6.2...v0.6.3)

- [b9a595f](https://github.com/robinebers/openusage/commit/b9a595f) fix(analytics): reduce noisy event volume with dedupe guards (#172) by @robinebers
- [3e8e3b7](https://github.com/robinebers/openusage/commit/3e8e3b7) feat(codex): surface GPT-5.3-Codex-Spark per-model rate limits (#176) by @robinebers
- [6ca4794](https://github.com/robinebers/openusage/commit/6ca4794) fix(codex): replace var with const/let in rate-limit loop by @robinebers
- [abe3f24](https://github.com/robinebers/openusage/commit/abe3f24) chore: bump version to 0.6.3 by @robinebers

## v0.6.2

### New Features
- Implement Tauri runtime check for event tracking by @robinebers

### Bug Fixes
- Fix whitelisted env vars not being resolved from terminal zsh ([#167](https://github.com/robinebers/openusage/pull/167)) by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.1...v0.6.2](https://github.com/robinebers/openusage/compare/v0.6.1...v0.6.2)

- [824e3da](https://github.com/robinebers/openusage/commit/824e3da) fix(plugin-engine): read whitelisted env vars from terminal zsh (#167) by @robinebers
- [ffb8883](https://github.com/robinebers/openusage/commit/ffb8883) feat(analytics): implement Tauri runtime check for event tracking by @robinebers

## 0.6.0

### New Features
- feat: add global shortcut to toggle panel ([#132](https://github.com/robinebers/openusage/pull/132)) by @MuhammadAli511
- Feat/perplexity plugin ([#138](https://github.com/robinebers/openusage/pull/138)) by @garanda21
- Add Factory/Droid plugin provider ([#130](https://github.com/robinebers/openusage/pull/130)) by @MuhammadAli511

### Bug Fixes
- fix(provider-card): update progress marker logic to hide when pace is unavailable by @robinebers
- fix: improve pace meter tooltip copy, marker logic, and styling ([#147](https://github.com/robinebers/openusage/pull/147)) by @robinebers
- fix(provider-card): streamline reset label formatting by @robinebers
- fix(codex): support keychain-backed auth storage ([#146](https://github.com/robinebers/openusage/pull/146)) by @robinebers
- fix: keep reset labels at "Resets soon" near reset ([#143](https://github.com/robinebers/openusage/pull/143)) by @robinebers
- Update AGENTS.md to include new guideline for executive summaries by @robinebers
- Reset timers display mode ([#142](https://github.com/robinebers/openusage/pull/142)) by @robinebers
- pacing: Add progress-bar pace marker ([#140](https://github.com/robinebers/openusage/pull/140)) by @robinebers
- Update README.md to add warning about main branch stability before Stack subsection. by @robinebers
- Next update label refresh ([#141](https://github.com/robinebers/openusage/pull/141)) by @robinebers
- fix(update): soften transient update check error UX ([#139](https://github.com/robinebers/openusage/pull/139)) by @robinebers

### Refactor
- Enhance redaction functionality and update AGENTS.md guidelines by @robinebers
- feat(kimi, mock, perplexity, windsurf): enhance plugin tests and functionality by @robinebers

### Chores
- chore: bump version to 0.6.0 by @robinebers
- chore: bump version to 0.5.3 by @robinebers

---

### Changelog

**Full Changelog**: [v0.5.2...v0.6.0](https://github.com/robinebers/openusage/compare/v0.5.2...v0.6.0)

- [f99f1d2](https://github.com/robinebers/openusage/commit/f99f1d2) chore: bump version to 0.6.0 by @robinebers
- [740c3e5](https://github.com/robinebers/openusage/commit/740c3e5) chore: bump version to 0.5.3 by @robinebers
- [47268fe](https://github.com/robinebers/openusage/commit/47268fe) feat(kimi, mock, perplexity, windsurf): enhance plugin tests and functionality by @robinebers
- [b4c6934](https://github.com/robinebers/openusage/commit/b4c6934) fix(provider-card): update progress marker logic to hide when pace is unavailable by @robinebers
- [efba3e4](https://github.com/robinebers/openusage/commit/efba3e4) feat: add global shortcut to toggle panel (#132) by @MuhammadAli511
- [f86add4](https://github.com/robinebers/openusage/commit/f86add4) fix: improve pace meter tooltip copy, marker logic, and styling (#147) by @robinebers
- [f6cedf9](https://github.com/robinebers/openusage/commit/f6cedf9) fix(provider-card): streamline reset label formatting by @robinebers
- [54e5a90](https://github.com/robinebers/openusage/commit/54e5a90) fix(codex): support keychain-backed auth storage (#146) by @robinebers
- [79a530f](https://github.com/robinebers/openusage/commit/79a530f) Feat/perplexity plugin (#138) by @garanda21
- [e4bdae2](https://github.com/robinebers/openusage/commit/e4bdae2) fix: keep reset labels at "Resets soon" near reset (#143) by @robinebers
- [39346b1](https://github.com/robinebers/openusage/commit/39346b1) Update AGENTS.md to include new guideline for executive summaries by @robinebers
- [4075e47](https://github.com/robinebers/openusage/commit/4075e47) Enhance redaction functionality and update AGENTS.md guidelines by @robinebers
- [8f7907e](https://github.com/robinebers/openusage/commit/8f7907e) Reset timers display mode (#142) by @robinebers
- [5ce2d9b](https://github.com/robinebers/openusage/commit/5ce2d9b) pacing: Add progress-bar pace marker (#140) by @robinebers
- [cdcddde](https://github.com/robinebers/openusage/commit/cdcddde) Update README.md to add warning about main branch stability before Stack subsection. by @robinebers
- [cf71b2e](https://github.com/robinebers/openusage/commit/cf71b2e) Next update label refresh (#141) by @robinebers
- [e23091c](https://github.com/robinebers/openusage/commit/e23091c) Add Factory/Droid plugin provider (#130) by @MuhammadAli511
- [ffdab91](https://github.com/robinebers/openusage/commit/ffdab91) fix(update): soften transient update check error UX (#139) by @robinebers

## v0.5.2

### New Features
- Add Aptabase analytics events for key user interactions ([#124](https://github.com/robinebers/openusage/pull/124)) by @robinebers
- Antigravity OAuth fallback ([#128](https://github.com/robinebers/openusage/pull/128)) by @validatedev

### Bug Fixes
- Added a little `pr-review` command for Cursor that makes reviewing PRs easier by @robinebers

### Chores
- Update icon assets by replacing the main icon and removing outdated iOS icon exports ([#125](https://github.com/robinebers/openusage/pull/125)) by @robinebers
- Bump version to 0.5.2 by @robinebers

---

### Changelog

**Full Changelog**: [v0.5.1...v0.5.2](https://github.com/robinebers/openusage/compare/v0.5.1...v0.5.2)

- [e80f8a4](https://github.com/robinebers/openusage/commit/e80f8a4) chore: bump version to 0.5.2 by @robinebers
- [d067b1f](https://github.com/robinebers/openusage/commit/d067b1f) feat: Antigravity OAuth fallback (#128) by @validatedev
- [9deed51](https://github.com/robinebers/openusage/commit/9deed51) Added a little `pr-review` command for Cursor that makes reviewing PRs easier by @robinebers
- [7f6a42d](https://github.com/robinebers/openusage/commit/7f6a42d) feat: add Aptabase analytics events for key user interactions (#124) by @robinebers
- [1386897](https://github.com/robinebers/openusage/commit/1386897) chore: update icon assets by replacing the main icon and removing outdated iOS icon exports (#125) by @robinebers

## v0.5.1

### New Features
- Add Amp provider plugin ([#111](https://github.com/robinebers/openusage/pull/111)) by @validatedev
- Add Kimi provider plugin with full-color icon support ([#109](https://github.com/robinebers/openusage/pull/109)) by @Yan-Yu-Lin
- Add Windsurf Next variant support ([#114](https://github.com/robinebers/openusage/pull/114)) by @robinebers
- Add Applications drag target layout for macOS DMG ([#113](https://github.com/robinebers/openusage/pull/113)) by @daeshawnballard

### Bug Fixes
- Stop showing billing cycle pacing for Windsurf flex credits ([#119](https://github.com/robinebers/openusage/pull/119)) by @robinebers
- Support Cursor Enterprise accounts with request-based usage ([#118](https://github.com/robinebers/openusage/pull/118)) by @iicdii

### Chores
- Update README.md to encourage community contributions by @robinebers
- Update README.md to include Amp provider in supported providers list by @robinebers
- Update AGENTS.md to include PR preparation guidelines by @robinebers
- Update README.md to highlight AI-generated project features by @robinebers

---

### Changelog

**Full Changelog**: [v0.5.0...v0.5.1](https://github.com/robinebers/openusage/compare/v0.5.0...v0.5.1)

- [98e861c](https://github.com/robinebers/openusage/commit/98e861c) fix(windsurf): stop showing billing cycle pacing for flex credits (#119) by @robinebers
- [f6a8bfc](https://github.com/robinebers/openusage/commit/f6a8bfc) fix(cursor): support Enterprise accounts with request-based usage (#118) by @iicdii
- [09187ec](https://github.com/robinebers/openusage/commit/09187ec) docs: update README.md to encourage community contributions by @robinebers
- [30583f4](https://github.com/robinebers/openusage/commit/30583f4) docs: update README.md to include Amp provider in supported providers list by @robinebers
- [65e7913](https://github.com/robinebers/openusage/commit/65e7913) feat: add Amp provider plugin (#111) by @validatedev
- [28a92f2](https://github.com/robinebers/openusage/commit/28a92f2) feat(kimi): add Kimi provider plugin with full-color icon support (#109) by @Yan-Yu-Lin
- [8ad9283](https://github.com/robinebers/openusage/commit/8ad9283) docs: update AGENTS.md to include PR preparation guidelines by @robinebers
- [fd92d28](https://github.com/robinebers/openusage/commit/fd92d28) windsurf: add Windsurf Next variant support (#114) by @robinebers
- [d28384d](https://github.com/robinebers/openusage/commit/d28384d) tauri(dmg): add Applications drag target layout (#113) by @daeshawnballard
- [caa12e5](https://github.com/robinebers/openusage/commit/caa12e5) docs: update README.md to highlight AI-generated project features by @robinebers

## v0.5.0

### New Features
- Auto-disable new non-default plugins ([#105](https://github.com/robinebers/openusage/pull/105)) by @robinebers
- Resolve auth path via CODEX_HOME and host env API ([#90](https://github.com/robinebers/openusage/pull/90)) by @igalarzab
- Add name field to redaction logic and corresponding tests by @robinebers
- Add Windsurf plugin provider ([#93](https://github.com/robinebers/openusage/pull/93)) by @robinebers
- Add Antigravity plugin provider ([#91](https://github.com/robinebers/openusage/pull/91)) by @robinebers

### Bug Fixes
- Updated dark theme, scrollable panel, and sidebar refinements ([#88](https://github.com/robinebers/openusage/pull/88)) by @robinebers

### Refactor
- Simplify HTTP request handling in probePort function by @robinebers

### Chores
- Bump reqwest from 0.12.28 to 0.13.2 in /src-tauri ([#104](https://github.com/robinebers/openusage/pull/104)) by @dependabot
- Bump tauri-plugin-updater in /src-tauri ([#99](https://github.com/robinebers/openusage/pull/99)) by @dependabot
- Bump rquickjs from 0.10.0 to 0.11.0 in /src-tauri ([#98](https://github.com/robinebers/openusage/pull/98)) by @dependabot
- Bump @vitejs/plugin-react from 4.7.0 to 5.1.3 ([#100](https://github.com/robinebers/openusage/pull/100)) by @dependabot
- Bump jsdom from 27.4.0 to 28.0.0 ([#101](https://github.com/robinebers/openusage/pull/101)) by @dependabot
- Bump typescript from 5.8.3 to 5.9.3 ([#102](https://github.com/robinebers/openusage/pull/102)) by @dependabot
- Bump time from 0.3.46 to 0.3.47 in /src-tauri ([#103](https://github.com/robinebers/openusage/pull/103)) by @dependabot
- Add open-source community files and CI workflows ([#95](https://github.com/robinebers/openusage/pull/95)) by @robinebers
- Update README.md to reflect new provider additions and modify upcoming features section by @robinebers
- Update package metadata in Cargo.toml by @robinebers
- Bump version to 0.5.0 by @robinebers

---

### Changelog

**Full Changelog**: [v0.4.2...v0.5.0](https://github.com/robinebers/openusage/compare/v0.4.2...v0.5.0)

- [f1cf2bc](https://github.com/robinebers/openusage/commit/f1cf2bc) feat(settings): auto-disable new non-default plugins (#105) by @robinebers
- [c7bf1cc](https://github.com/robinebers/openusage/commit/c7bf1cc) feat(codex): resolve auth path via CODEX_HOME and host env API (#90) by @igalarzab
- [c49ce70](https://github.com/robinebers/openusage/commit/c49ce70) chore(deps): bump reqwest from 0.12.28 to 0.13.2 in /src-tauri (#104) by @dependabot
- [83f8c44](https://github.com/robinebers/openusage/commit/83f8c44) chore(deps): bump tauri-plugin-updater in /src-tauri (#99) by @dependabot
- [a07abf9](https://github.com/robinebers/openusage/commit/a07abf9) chore(deps): bump rquickjs from 0.10.0 to 0.11.0 in /src-tauri (#98) by @dependabot
- [c5167b7](https://github.com/robinebers/openusage/commit/c5167b7) chore(deps-dev): bump @vitejs/plugin-react from 4.7.0 to 5.1.3 (#100) by @dependabot
- [0f14a64](https://github.com/robinebers/openusage/commit/0f14a64) chore(deps-dev): bump jsdom from 27.4.0 to 28.0.0 (#101) by @dependabot
- [7dfb11e](https://github.com/robinebers/openusage/commit/7dfb11e) chore(deps-dev): bump typescript from 5.8.3 to 5.9.3 (#102) by @dependabot
- [5c9b948](https://github.com/robinebers/openusage/commit/5c9b948) chore(deps): bump time from 0.3.46 to 0.3.47 in /src-tauri (#103) by @dependabot
- [b1e52eb](https://github.com/robinebers/openusage/commit/b1e52eb) docs: Update README.md to reflect new provider additions and modify upcoming features section by @robinebers
- [661ca68](https://github.com/robinebers/openusage/commit/661ca68) chore: Add open-source community files and CI workflows (#95) by @robinebers
- [bb57cd3](https://github.com/robinebers/openusage/commit/bb57cd3) refactor(antigravity): simplify HTTP request handling in probePort function by @robinebers
- [463fb0c](https://github.com/robinebers/openusage/commit/463fb0c) feat(redaction): Add name field to redaction logic and corresponding tests by @robinebers
- [f2d1e9e](https://github.com/robinebers/openusage/commit/f2d1e9e) feat(windsurf): Add Windsurf plugin provider (#93) by @robinebers
- [01d81ce](https://github.com/robinebers/openusage/commit/01d81ce) feat(antigravity): Add Antigravity plugin provider (#91) by @robinebers
- [7905417](https://github.com/robinebers/openusage/commit/7905417) ui: Updated dark theme, scrollable panel, and sidebar refinements (#88) by @robinebers
- [46a452e](https://github.com/robinebers/openusage/commit/46a452e) chore: update package metadata in Cargo.toml by @robinebers
- [f73192c](https://github.com/robinebers/openusage/commit/f73192c) chore: bump version to 0.5.0 by @robinebers

## v0.4.2

### New Features
- Add Help button to open GitHub issues page by @robinebers
- Pacing tooltip projection and limit hit ETA ([#87](https://github.com/robinebers/openusage/pull/87)) by @marcjaner
- Add provider icon style option to tray ([#81](https://github.com/robinebers/openusage/pull/81)) by @robinebers

### Chores
- Bump version to 0.4.2
- Bump version to 0.4.1

---

### Changelog

**Full Changelog**: [v0.4.1...v0.4.2](https://github.com/robinebers/openusage/compare/v0.4.1...v0.4.2)

- [0d52efd](https://github.com/robinebers/openusage/commit/0d52efd) chore: bump version to 0.4.2
- [0d17daa](https://github.com/robinebers/openusage/commit/0d17daa) feat(side-nav): add Help button to open GitHub issues page
- [0605d4b](https://github.com/robinebers/openusage/commit/0605d4b) Feat/pacing tooltip projection and limit hit eta (#87)
- [618cca7](https://github.com/robinebers/openusage/commit/618cca7) chore: bump version to 0.4.1
- [de401e3](https://github.com/robinebers/openusage/commit/de401e3) tray: add provider icon style option (#81)

## v0.4.1

### New Features
- Add provider icon style and enhance settings functionality by @robinebers

### Bug Fixes
- Update references from "Claude" to "Provider" for consistency by @robinebers

### Refactor
- Update section headings and descriptions for clarity by @robinebers
- Update checkbox component to use new primitive and improve styling by @robinebers

### Chores
- Update dark theme colors and enhance settings page text by @robinebers
- Update SVG attributes for improved icon rendering by @robinebers

---

### Changelog

**Full Changelog**: [v0.4.0...v0.4.1](https://github.com/robinebers/openusage/compare/v0.4.0...v0.4.1)

- [cd6225e](https://github.com/robinebers/openusage/commit/cd6225e) chore: bump version to 0.4.1
- [eb6a92a](https://github.com/robinebers/openusage/commit/eb6a92a) style(settings): update SVG attributes for improved icon rendering
- [c8795f2](https://github.com/robinebers/openusage/commit/c8795f2) fix(provider): update references from "Claude" to "Provider" for consistency
- [8b0022a](https://github.com/robinebers/openusage/commit/8b0022a) refactor(settings): update section headings and descriptions for clarity
- [13b5cd2](https://github.com/robinebers/openusage/commit/13b5cd2) refactor(checkbox): update checkbox component to use new primitive and improve styling
- [8efb8e7](https://github.com/robinebers/openusage/commit/8efb8e7) feat(tray): add provider icon style and enhance settings functionality
- [2efe6dd](https://github.com/robinebers/openusage/commit/2efe6dd) style: update dark theme colors and enhance settings page text

## v0.4.0

### New Features
- Customizable tray icon styles and percentage text ([#78](https://github.com/robinebers/openusage/pull/78))

### Bug Fixes
- Prevent background timer suspension on macOS ([#74](https://github.com/robinebers/openusage/pull/74))
- Remove emdashes ([8d456f9](https://github.com/robinebers/openusage/commit/8d456f9))

### Chores
- Update icon assets and icon configuration ([32948c9](https://github.com/robinebers/openusage/commit/32948c9))
- Update README to enhance clarity and detail ([8e3a7e2](https://github.com/robinebers/openusage/commit/8e3a7e2))

---

### Changelog

**Full Changelog**: [v0.3.1...v0.4.0](https://github.com/robinebers/openusage/compare/v0.3.1...v0.4.0)

- [a0b1519](https://github.com/robinebers/openusage/commit/a0b1519) chore: bump version to 0.4.0
- [168f23b](https://github.com/robinebers/openusage/commit/168f23b) tray: customizable icon styles and percentage text (#78)
- [8d456f9](https://github.com/robinebers/openusage/commit/8d456f9) remove god damn emdashes
- [8e3a7e2](https://github.com/robinebers/openusage/commit/8e3a7e2) docs: update README to enhance clarity and detail
- [32948c9](https://github.com/robinebers/openusage/commit/32948c9) chore: update icon assets and icon configuration
- [4800e36](https://github.com/robinebers/openusage/commit/4800e36) fix(macos): prevent background timer suspension (#74)

## v0.3.1

### Bug Fixes
- Prevent background timer suspension on macOS by disabling WebKit's `inactiveSchedulingPolicy` and App Nap at startup
- Use `NSActivityUserInitiatedAllowingIdleSystemSleep` instead of `NSActivityBackground` to reliably prevent App Nap

---

### Changelog

**Full Changelog**: [v0.3.0...v0.3.1](https://github.com/robinebers/openusage/compare/v0.3.0...v0.3.1)

- [19164fa](https://github.com/robinebers/openusage/commit/19164fa) feat(macos): add objc2 dependencies and implement app nap and webview suspension handling
- [6ff19ba](https://github.com/robinebers/openusage/commit/6ff19ba) fix(macos): use NSActivityUserInitiatedAllowingIdleSystemSleep instead of NSActivityBackground
- [c532c69](https://github.com/robinebers/openusage/commit/c532c69) chore: bump version to 0.3.1

## v0.3.0

### New Features
- Add Copilot plugin and tests ([#69](https://github.com/robinebers/openusage/pull/69)) by @tomhhealy
- Add pace tracking indicator for usage metrics ([#70](https://github.com/robinebers/openusage/pull/70)) by @robinebers
- Enhance log redaction and add new sensitive keys ([#72](https://github.com/robinebers/openusage/pull/72)) by @robinebers

### Chores
- Update progress line structure in Copilot plugin.json by @robinebers

---

### Changelog

**Full Changelog**: [v0.2.2...v0.3.0](https://github.com/robinebers/openusage/compare/v0.2.2...v0.3.0)

- [819b9bb](https://github.com/robinebers/openusage/commit/819b9bb) chore: bump version to 0.3.0
- [8d8da67](https://github.com/robinebers/openusage/commit/8d8da67) refactor(copilot): update progress line structure in plugin.json
- [b86478d](https://github.com/robinebers/openusage/commit/b86478d) feat(logging): enhance log redaction and add new sensitive keys (#72)
- [c85b3f1](https://github.com/robinebers/openusage/commit/c85b3f1) feat: add Copilot plugin and tests (#69)
- [acaac92](https://github.com/robinebers/openusage/commit/acaac92) feat: Add pace tracking indicator for usage metrics (#70)

## v0.2.2

### New Features
- Conditional primary metrics + Cursor credits balance ([#68](https://github.com/robinebers/openusage/pull/68)) by @robinebers

---

### Changelog

**Full Changelog**: [v0.2.1...v0.2.2](https://github.com/robinebers/openusage/compare/v0.2.1...v0.2.2)

- [eb99a67](https://github.com/robinebers/openusage/commit/eb99a67) chore: bump version to 0.2.2
- [c280059](https://github.com/robinebers/openusage/commit/c280059) plugins: Conditional primary metrics + Cursor credits balance (#68)

## v0.2.1

### New Features
- Add 15-minute auto-check interval for app updates ([#66](https://github.com/robinebers/openusage/pull/66)) by @robinebers

### Bug Fixes
- Use immutable=1 to prevent WAL false negatives after sleep ([#65](https://github.com/robinebers/openusage/pull/65)) by @robinebers

---

### Changelog

**Full Changelog**: [v0.2.0...v0.2.1](https://github.com/robinebers/openusage/compare/v0.2.0...v0.2.1)

- [0aff5a3](https://github.com/robinebers/openusage/commit/0aff5a3) chore: bump version to 0.2.1
- [46f76ea](https://github.com/robinebers/openusage/commit/46f76ea) feat(update): add 15-minute auto-check interval for app updates (#66)
- [c4cbdfa](https://github.com/robinebers/openusage/commit/c4cbdfa) fix(sqlite): use immutable=1 to prevent WAL false negatives after sleep (#65)

## v0.2.0

### New Features
- **Usage display modes**: Show "used" or "left" with configurable default ([#60](https://github.com/robinebers/openusage/pull/60), [#63](https://github.com/robinebers/openusage/pull/63))
- **Debug logging**: Tray menu option to set log level for troubleshooting ([#64](https://github.com/robinebers/openusage/pull/64))
- **Escape to dismiss**: Press Escape to hide the panel
- **Update button animation**: Animated border beam on available updates ([#58](https://github.com/robinebers/openusage/pull/58))

### Bug Fixes
- Fix a keychain JSON storage causing credential read failures in Claude ([#61](https://github.com/robinebers/openusage/pull/61))
- Exclude test files from production builds ([#62](https://github.com/robinebers/openusage/pull/62))
- Adjust panel positioning on macOS ([#59](https://github.com/robinebers/openusage/pull/59))

---

**Full Changelog**: [v0.1.2...v0.2.0](https://github.com/robinebers/openusage/compare/v0.1.2...v0.2.0)

## 0.1.2

### New Features
- Dynamic tray icon with primary progress bars + about dialog ([#51](https://github.com/robinebers/openusage/pull/51))
- Add AboutDialog and enhance version display interaction ([#49](https://github.com/robinebers/openusage/pull/49))
- Add settings button, plugins subtitle, and tray context menu ([#50](https://github.com/robinebers/openusage/pull/50))

### Bug Fixes
- Update subtitle fallback for session status in Claude and Codex plugins and fix about plugin text, replaced home icon with OpenUsage logo ([#57](https://github.com/robinebers/openusage/pull/57))
- Resolve gray border artifact on macOS transparent windows ([#53](https://github.com/robinebers/openusage/pull/53))
- Handle hex-encoded keychain credentials ([#48](https://github.com/robinebers/openusage/pull/48))

### Refactor
- Refactor plugins to use ctx.util helpers ([#54](https://github.com/robinebers/openusage/pull/54))
- Standardize provider documentation to minimal format ([#52](https://github.com/robinebers/openusage/pull/52))

### Chores
- Update AGENTS.md with new tauri-action parallel build information

---

### Changelog

**Full Changelog**: [v0.1.1...v0.1.2](https://github.com/robinebers/openusage/compare/v0.1.1...v0.1.2)

- [07854d1](https://github.com/robinebers/openusage/commit/07854d1) fix(plugins): update subtitle fallback for session status in Claude and Codex plugins and fix about plugin text, replaced home icon with OpenUsage logo (#57)
- [cfeb157](https://github.com/robinebers/openusage/commit/cfeb157) fix(panel): resolve gray border artifact on macOS transparent windows (#53)
- [1cf9c68](https://github.com/robinebers/openusage/commit/1cf9c68) Refactor plugins to use ctx.util helpers (#54)
- [9e276bf](https://github.com/robinebers/openusage/commit/9e276bf) Standardize provider documentation to minimal format (#52)
- [b2495ad](https://github.com/robinebers/openusage/commit/b2495ad) feat(tray): Dynamic tray icon with primary progress bars + about dialog (#51)
- [8dc1e99](https://github.com/robinebers/openusage/commit/8dc1e99) Add settings button, plugins subtitle, and tray context menu (#50)
- [8768474](https://github.com/robinebers/openusage/commit/8768474) feat(panel-footer): add AboutDialog and enhance version display interaction (#49)
- [5f14123](https://github.com/robinebers/openusage/commit/5f14123) fix(claude): handle hex-encoded keychain credentials (#48)
- [4808686](https://github.com/robinebers/openusage/commit/4808686) docs: update AGENTS.md with new tauri-action parallel build information

## v0.1.1

### New Features
- Add line scope API for overview/detail filtering ([#44](https://github.com/robinebers/openusage/pull/44))
- Add upward-pointing arrow to tray panel ([#43](https://github.com/robinebers/openusage/pull/43))
- Replace refresh button with countdown timer ([#41](https://github.com/robinebers/openusage/pull/41))
- fetch and display app version in footer

### Refactor
- streamline update handling by removing download trigger

### Chores
- enhance publish workflow and plugin initialization
- update publish workflow and remove unused bundled_plugins directory
- update documentation and .gitignore for auto-update interval feature ([#42](https://github.com/robinebers/openusage/pull/42))
- update screenshot asset

---

### Changelog

**Full Changelog**: [v0.0.2...v0.1.1](https://github.com/robinebers/openusage/compare/v0.0.2...v0.1.1)

- [6a72419](https://github.com/robinebers/openusage/commit/6a72419) plugins: Add line scope API for overview/detail filtering (#44)
- [aa4be14](https://github.com/robinebers/openusage/commit/aa4be14) Add upward-pointing arrow to tray panel (#43)
- [6c5502c](https://github.com/robinebers/openusage/commit/6c5502c) chore: update documentation and .gitignore for auto-update interval feature (#42)
- [0b918a8](https://github.com/robinebers/openusage/commit/0b918a8) chore: update screenshot asset
- [2d1c367](https://github.com/robinebers/openusage/commit/2d1c367) footer: Replace refresh button with countdown timer (#41)
- [f17ba61](https://github.com/robinebers/openusage/commit/f17ba61) feat: fetch and display app version in footer
- [55e30f4](https://github.com/robinebers/openusage/commit/55e30f4) refactor: streamline update handling by removing download trigger
- [b52ec74](https://github.com/robinebers/openusage/commit/b52ec74) chore: enhance publish workflow and plugin initialization
- [8feca7a](https://github.com/robinebers/openusage/commit/8feca7a) chore: update publish workflow and remove unused bundled_plugins directory

## v0.1.0

### Changelog

**Full Changelog**: [v0.0.2...v0.1.0](https://github.com/robinebers/openusage/compare/v0.0.2...v0.1.0)

- Replace refresh button with countdown timer ([#41](https://github.com/robinebers/openusage/pull/41)) by @robinebers
- Fix broken links and update outdated refresh references ([#42](https://github.com/robinebers/openusage/pull/42)) by @robinebers
- Add upward-pointing arrow to tray panel ([#43](https://github.com/robinebers/openusage/pull/43)) by @robinebers
- Add line scope API for overview/detail filtering ([#44](https://github.com/robinebers/openusage/pull/44)) by @robinebers

## v0.0.2

*No release notes*

## v0.0.1

*No release notes*
