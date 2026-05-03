# Changelog

## v0.6.22

### Bug Fixes
- fix(ccusage): kill timed-out process groups ([#433](https://github.com/robinebers/openusage/pull/433)) by @robinebers
- fix(claude): support hashed macOS keychain service name (closes #423) ([#424](https://github.com/robinebers/openusage/pull/424)) by @robinebers

### Chores
- chore(deps): bump tauri from 2.10.3 to 2.11.0 in /src-tauri ([#429](https://github.com/robinebers/openusage/pull/429)) by @dependabot
- chore(deps): bump reqwest from 0.13.2 to 0.13.3 in /src-tauri ([#428](https://github.com/robinebers/openusage/pull/428)) by @dependabot

---

### Changelog

**Full Changelog**: [v0.6.21...v0.6.22](https://github.com/robinebers/openusage/compare/v0.6.21...v0.6.22)

- [2730669](https://github.com/robinebers/openusage/commit/2730669a866cef4d38533466094e2347ae3d1f26) fix(ccusage): kill timed-out process groups (#433) by @robinebers
- [5651a3a](https://github.com/robinebers/openusage/commit/5651a3ab32cd44c337fad3cb6749633afd62c492) fix(claude): only hash keychain when CLAUDE_CONFIG_DIR is set by @robinebers
- [1562a07](https://github.com/robinebers/openusage/commit/1562a07e85a27d00c14cd9e919862314d430ca25) fix(claude): support hashed macOS keychain service name (closes #423) by @robinebers
- [2b5c5db](https://github.com/robinebers/openusage/commit/2b5c5db95d73013c2917bd3540ee54d1ad9fb480) chore(deps): bump tauri from 2.10.3 to 2.11.0 in /src-tauri by @dependabot
- [ee02c4c](https://github.com/robinebers/openusage/commit/ee02c4c582a9dfc7ba3ece20168919cb8616583c) chore(deps): bump reqwest from 0.13.2 to 0.13.3 in /src-tauri by @dependabot

## v0.6.21

### Bug Fixes
- fix(codex): lazy-load keychain auth fallback ([#419](https://github.com/robinebers/openusage/pull/419)) by @validatedev

### Chores
- docs(codex): clarify file-based OAuth credentials description ([#419](https://github.com/robinebers/openusage/pull/419)) by @validatedev
- docs(agents): replace internal HQ header with OpenUsage title by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.20...v0.6.21](https://github.com/robinebers/openusage/compare/v0.6.20...v0.6.21)

- [6f52da5](https://github.com/robinebers/openusage/commit/6f52da586bef10d97b84e0dfadc9b8ced3e9376e) docs(codex): clarify file-based OAuth credentials description by @validatedev
- [e7b4072](https://github.com/robinebers/openusage/commit/e7b4072d280dd6cf6cd6d4a626b1c2a4e948da1f) fix(codex): lazy-load keychain auth fallback by @validatedev
- [1395f20](https://github.com/robinebers/openusage/commit/1395f2083d78a0bac224e095a0265b379410daec) docs(agents): replace internal HQ header with OpenUsage title by @robinebers

## v0.6.20

### New Features
- feat: preserve usage data during refresh (stale-while-revalidate) ([#386](https://github.com/robinebers/openusage/pull/386)) by @DoozyX
- Add agent worktree setup by @robinebers

### Bug Fixes
- fix(factory): retry with GET when usage endpoint returns HTTP 405 ([#390](https://github.com/robinebers/openusage/pull/390)) by @allensama0403
- fix: read OAuth tokens from unified state key ([#392](https://github.com/robinebers/openusage/pull/392)) by @validatedev
- fix: only refresh Antigravity OAuth on auth failure ([#392](https://github.com/robinebers/openusage/pull/392)) by @validatedev
- address review feedback on stale-while-revalidate PR ([#386](https://github.com/robinebers/openusage/pull/386)) by @DoozyX
- address second round of review feedback on stale-while-revalidate PR ([#386](https://github.com/robinebers/openusage/pull/386)) by @DoozyX
- Prevent shell noise from breaking Z.ai auth headers ([#398](https://github.com/robinebers/openusage/pull/398)) by @KYankee6
- Prevent empty marker output from becoming a fake env value ([#398](https://github.com/robinebers/openusage/pull/398)) by @KYankee6
- fix(gemini): refresh OAuth tokens on Homebrew-installed gemini-cli ([#401](https://github.com/robinebers/openusage/pull/401)) by @Rich627
- fix(codex): map pro to Pro 20x (closes #408) ([#411](https://github.com/robinebers/openusage/pull/411)) by @validatedev
- Fix Codex auth fallback ([#413](https://github.com/robinebers/openusage/pull/413)) by @robinebers

### Refactor
- refactor: rename probe()'s `proto` var to `dbTokens` ([#392](https://github.com/robinebers/openusage/pull/392)) by @validatedev

### Chores
- chore(gemini): clarify OAuth candidate warn message ([#401](https://github.com/robinebers/openusage/pull/401)) by @Rich627
- chore(deps): bump uuid from 1.23.0 to 1.23.1 in /src-tauri ([#405](https://github.com/robinebers/openusage/pull/405)) by @dependabot[bot]
- chore(deps): bump tokio from 1.51.1 to 1.52.1 in /src-tauri ([#406](https://github.com/robinebers/openusage/pull/406)) by @dependabot[bot]

---

### Changelog

**Full Changelog**: [v0.6.15...v0.6.20](https://github.com/robinebers/openusage/compare/v0.6.15...v0.6.20)

- [722e91b](https://github.com/robinebers/openusage/commit/722e91b5a3a1b2c4db882a5d01e608c8552deea0) fix(factory): retry with GET when usage endpoint returns HTTP 405 by @allensama0403
- [4625376](https://github.com/robinebers/openusage/commit/4625376c3cc9efb2e97294a3d5d73cff9753a4cb) fix: read OAuth tokens from unified state key by @validatedev
- [6147b1c](https://github.com/robinebers/openusage/commit/6147b1c834efec96746f4ba0e6d05d2b6340dbd5) refactor: rename probe()'s `proto` var to `dbTokens` by @validatedev
- [cfa1e69](https://github.com/robinebers/openusage/commit/cfa1e699537aee53a418abdbfe1ad671edc28b88) fix: only refresh Antigravity OAuth on auth failure by @validatedev
- [0c5185b](https://github.com/robinebers/openusage/commit/0c5185bb1827dc07ca02ebf6f0575b94f3029c63) feat: preserve usage data during refresh (stale-while-revalidate) by @DoozyX
- [d794535](https://github.com/robinebers/openusage/commit/d79453533e683eb1b6c76405fe970283295f31d5) address review feedback on stale-while-revalidate PR by @DoozyX
- [7afc4fe](https://github.com/robinebers/openusage/commit/7afc4fe71aa8e7217167614c10c4823bac2328a5) address second round of review feedback on stale-while-revalidate PR by @DoozyX
- [5a7de06](https://github.com/robinebers/openusage/commit/5a7de06af5e45fbe3daf21f2c7d51115d28b1111) Prevent shell noise from breaking Z.ai auth headers by @KYankee6
- [7cf7a6f](https://github.com/robinebers/openusage/commit/7cf7a6f68da833893099851a969a458db11100eb) Prevent empty marker output from becoming a fake env value by @KYankee6
- [96abffb](https://github.com/robinebers/openusage/commit/96abffb517e75b55ed658f53dce25bf5bb894b44) fix(gemini): refresh OAuth tokens on Homebrew-installed gemini-cli by @Rich627
- [1a91101](https://github.com/robinebers/openusage/commit/1a911019a190bc90180c800a35f94d9caeab34a1) chore(gemini): clarify OAuth candidate warn message by @Rich627
- [a12292d](https://github.com/robinebers/openusage/commit/a12292d0db436814bad082ddfd12cb28cafc895c) chore(deps): bump uuid from 1.23.0 to 1.23.1 in /src-tauri by @dependabot[bot]
- [bee03a9](https://github.com/robinebers/openusage/commit/bee03a908fe70f9e6f84b2f20b41115542c7c188) chore(deps): bump tokio from 1.51.1 to 1.52.1 in /src-tauri by @dependabot[bot]
- [b61116e](https://github.com/robinebers/openusage/commit/b61116e8b18614f8a5b661e8eecec716b84bb5bb) fix(codex): map pro to Pro 20x (closes #408) by @validatedev
- [951c67b](https://github.com/robinebers/openusage/commit/951c67ba5beb2d47586a2948403e956509adab2d) Merge pull request #411 from robinebers/fix/codex-change-10x-to-20x-for-pro-plan by @validatedev
- [35b0787](https://github.com/robinebers/openusage/commit/35b0787fc7ad5a5dfb926f9300b4a629324783a5) Merge pull request #405 from robinebers/dependabot/cargo/src-tauri/uuid-1.23.1 by @dependabot[bot]
- [9a80827](https://github.com/robinebers/openusage/commit/9a80827468eeb3eb3d8db1e58f6516c9eb8b0c01) Merge pull request #406 from robinebers/dependabot/cargo/src-tauri/tokio-1.52.1 by @dependabot[bot]
- [a6072da](https://github.com/robinebers/openusage/commit/a6072da7f0bb50e72c8223163063d4f8c0494445) Merge pull request #401 from Rich627/fix/gemini-homebrew-bundle-refresh by @Rich627
- [3970022](https://github.com/robinebers/openusage/commit/3970022b11d098a87533eaada398596e3077f60d) Merge pull request #390 from allensama0403/fix/factory-405-usage-endpoint by @allensama0403
- [2c03270](https://github.com/robinebers/openusage/commit/2c032702fda2b04d09e5ff7a903d20fba3beea63) Merge pull request #392 from robinebers/fix/antigravity-oauth-local-import-schema-error by @validatedev
- [a9425ba](https://github.com/robinebers/openusage/commit/a9425ba1a4dbc60f9b3193acd5f53cfeecab07cd) Add agent worktree setup by @robinebers
- [f894473](https://github.com/robinebers/openusage/commit/f894473c0c80f1ca58223cd3142d63df7e5d4f56) Fix Codex auth fallback by @robinebers
- [b9e9f30](https://github.com/robinebers/openusage/commit/b9e9f309d86b0f2c01bf6a9e49ad9e2e0d69d36b) Merge pull request #413 from robinebers/cursor/1823929a by @robinebers
- [de8cf31](https://github.com/robinebers/openusage/commit/de8cf31d0860483309e757d295a84574de193767) Merge pull request #386 from DoozyX/claude/preserve-usage-on-refresh-1pNCN by @DoozyX
- [77ef460](https://github.com/robinebers/openusage/commit/77ef46033a5ce8a465c74c0eed7b683fb82545a5) Merge pull request #398 from KYankee6/fix/zai-env-header-noise by @KYankee6

## v0.6.15

### New Features
- feat(claude): add Claude Design weekly detail metric ([#388](https://github.com/robinebers/openusage/pull/388)) by @robinebers
- Add CLAUDE.md by @robinebers
- Add Codex environment config by @robinebers

### Bug Fixes
- fix(codex): map Codex plan labels to Pro 5x and Pro 10x ([#380](https://github.com/robinebers/openusage/pull/380)) by @arrowarcher1
- fix(claude): graceful 429 rate limit handling with Retry-After support ([#378](https://github.com/robinebers/openusage/pull/378)) by @zergzorg
- Update AGENTS.md by @robinebers
- Star history by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.14...v0.6.15](https://github.com/robinebers/openusage/compare/v0.6.14...v0.6.15)

- [cb16571](https://github.com/robinebers/openusage/commit/cb16571d969e7b2de44f9595fe09bcd7f1ed111e) feat(claude): add Claude Design weekly detail metric (#388) by @robinebers
- [87c45b6](https://github.com/robinebers/openusage/commit/87c45b66663b5d4662cdb6fd8bb46ef4c8ae4c5f) Add CLAUDE.md by @robinebers
- [455c857](https://github.com/robinebers/openusage/commit/455c857d2a4e2e5543a4295348fca9f70b1a3fcc) Update AGENTS.md by @robinebers
- [510cbe4](https://github.com/robinebers/openusage/commit/510cbe48651d4c9c58b17a16e3b7c0214244c3f0) fix(codex): map Codex plan labels to Pro 5x and Pro 10x (#380) by @arrowarcher1
- [0ffe3ad](https://github.com/robinebers/openusage/commit/0ffe3ad85a37b42723c56a494af216ee67978976) fix(claude): graceful 429 rate limit handling with Retry-After support (#378) by @zergzorg
- [06113d6](https://github.com/robinebers/openusage/commit/06113d6b94c6f8306e67aedf51b42f3f03d8b3e5) Add Codex environment config by @robinebers
- [abf6cff](https://github.com/robinebers/openusage/commit/abf6cffc3bc110abf306a82d45a67972e725b236) Star history by @robinebers

## v0.6.14

### New Features
- Clickable provider rows + session/weekly labels by @robinebers
- Integrate PromoClock peak/off-peak status ([#364](https://github.com/robinebers/openusage/pull/364)) by @validatedev
- Add cmd-arrow tab navigation by @robinebers

### Bug Fixes
- Session expired ([#363](https://github.com/robinebers/openusage/pull/363)) by @yhunko
- Prefer userTier.name over legacy planInfo.planName by @n3wr1ch
- Show panel before tray reposition by @robinebers
- Correct tray monitor positioning by @robinebers
- Position panel under tray icon on all entry paths without flicker by @robinebers

### Refactor
- Apply Copilot review — add typeof/trim guards, remove duplicate assertion by @n3wr1ch
- Dedupe panel focus helper by @robinebers

### Chores
- Bump tauri-plugin-updater in /src-tauri by @dependabot[bot]
- Bump tokio from 1.51.0 to 1.51.1 in /src-tauri by @dependabot[bot]

---

### Changelog

**Full Changelog**: [v0.6.13...v0.6.14](https://github.com/robinebers/openusage/compare/v0.6.13...v0.6.14)

- [57cc5bd](https://github.com/robinebers/openusage/commit/57cc5bd36bd1a2c189b1f00f3598f6695e1071d7) fix(settings,opencode): clickable provider rows + session/weekly labels by @robinebers
- [60cc426](https://github.com/robinebers/openusage/commit/60cc426f31f60c845ecb5fa9ba58703a18609314) fix(gemini): session expired (#363) by @yhunko
- [83551c1](https://github.com/robinebers/openusage/commit/83551c1cadb95ced4596ae846b07dfa51916de03) feat(claude): integrate PromoClock peak/off-peak status (#364) by @validatedev
- [cb63b20](https://github.com/robinebers/openusage/commit/cb63b20fa59152a4432220d95942c9a610b4e039) refactor: apply Copilot review — add typeof/trim guards, remove duplicate assertion by @n3wr1ch
- [996c7fe](https://github.com/robinebers/openusage/commit/996c7fee5aed915f50ffce8b498b92e883d87ebd) chore(deps): bump tauri-plugin-updater in /src-tauri by @dependabot[bot]
- [9479e34](https://github.com/robinebers/openusage/commit/9479e3476755a4ae08d59261ac341b7efd641de1) chore(deps): bump tokio from 1.51.0 to 1.51.1 in /src-tauri by @dependabot[bot]
- [d7cb0fc](https://github.com/robinebers/openusage/commit/d7cb0fc59885fcddf910b52d34b0d4d8136b02ab) fix(antigravity): prefer userTier.name over legacy planInfo.planName by @n3wr1ch
- [995a7fd](https://github.com/robinebers/openusage/commit/995a7fd2fbc05963869f6df6cc0079af7259c366) fix(panel): show before tray reposition by @robinebers
- [ae43e80](https://github.com/robinebers/openusage/commit/ae43e80e9896b833ce3c41b4341d221e09ead9a6) fix(panel): correct tray monitor positioning by @robinebers
- [d114de5](https://github.com/robinebers/openusage/commit/d114de5a68752f7f6b9a05452c46651a2d7461ed) fix(panel): position panel under tray icon on all entry paths without flicker by @robinebers
- [0d6e0ed](https://github.com/robinebers/openusage/commit/0d6e0ed70d776bfa3437872e2c40203f14401d6f) refactor: dedupe panel focus helper by @robinebers
- [8cfe6a9](https://github.com/robinebers/openusage/commit/8cfe6a919d23f3ec8542aa5e52203fa7da3d8ab8) feat: add cmd-arrow tab navigation by @robinebers

## v0.6.13

### New Features
- Add Kiro plugin for usage tracking and management by @sayuru-akash
- add Synthetic provider plugin by @ben-vargas
- add SOCKS5/HTTP proxy support via ~/.openusage/config.json by @zergzorg
- Support custom Claude OAuth config and credentials by @robinebers

### Bug Fixes
- address synthetic plugin review feedback by @ben-vargas
- scope keychain user lookup by @robinebers
- address PR 331 review comments by @robinebers
- use REST fallback for team-inferred accounts missing planUsage.limit by @drewwells
- skip fallback when percent usage is available by @drewwells
- prefer enterprise auth and handle missing limits by @drewwells
- correct proxy redaction output by @robinebers
- prevent relative config path when home dir is unavailable by @zergzorg
- load factory auth from droid v2 store ([#298](https://github.com/robinebers/openusage/pull/298)) by @davidarny
- Harden Windsurf quota parsing for missing and invalid balance data by @prayzey
- Handle missing Windsurf extra usage balance so quota still loads by @prayzey

### Refactor
- update release process to push commits and tags before creating GitHub releases by @robinebers

### Chores
- bump tokio from 1.50.0 to 1.51.0 in /src-tauri by @dependabot[bot]
- add proxy configuration guide by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.12...v0.6.13](https://github.com/robinebers/openusage/compare/v0.6.12...v0.6.13)

- [96eede6](https://github.com/robinebers/openusage/commit/96eede6a77c08494f23ca07247bf4b629304fe78) feat: Add Kiro plugin for usage tracking and management by @sayuru-akash
- [2a8f550](https://github.com/robinebers/openusage/commit/2a8f5505e66e305cdc0ba7610e2382f02aaad19e) fix: address synthetic plugin review feedback by @ben-vargas
- [8031849](https://github.com/robinebers/openusage/commit/8031849b557339e3212a614065e6db7b6385a29b) feat: add Synthetic provider plugin by @ben-vargas
- [110bee6](https://github.com/robinebers/openusage/commit/110bee64868396840d1f44e8c16f2c97d98bbe01) fix(claude): scope keychain user lookup by @robinebers
- [25b0029](https://github.com/robinebers/openusage/commit/25b00291fc1ff05fbe74b9de90fa49c493e7e464) fix: address PR 331 review comments by @robinebers
- [fed094a](https://github.com/robinebers/openusage/commit/fed094ae0413d3c4110e213db27fb1733a023efa) Support custom Claude OAuth config and credentials by @robinebers
- [b821f34](https://github.com/robinebers/openusage/commit/b821f34bd3a1b09153ec7d33a51399953105c1a3) fix(cursor): use REST fallback for team-inferred accounts missing planUsage.limit by @drewwells
- [6a5145b](https://github.com/robinebers/openusage/commit/6a5145b2c9b4a37df493f6c8a7a57d2200c402ba) fix(cursor): skip fallback when percent usage is available by @drewwells
- [64c9840](https://github.com/robinebers/openusage/commit/64c9840a01075e47ff1ae46c8cf899fc704ddc74) fix(cursor): prefer enterprise auth and handle missing limits by @drewwells
- [7dc38fe](https://github.com/robinebers/openusage/commit/7dc38fe961f393189fc79e87d934a2d0760987c6) docs: add proxy configuration guide by @robinebers
- [29c9ff0](https://github.com/robinebers/openusage/commit/29c9ff0e79d0eb2913f4ef6b50aa170bca6d3177) fix(config): correct proxy redaction output by @robinebers
- [2c27806](https://github.com/robinebers/openusage/commit/2c278068cdbfbd03937e232428271bc68208d778) fix: prevent relative config path when home dir is unavailable by @zergzorg
- [1f48faf](https://github.com/robinebers/openusage/commit/1f48fafe8699f0831ed6e387ea4e99f8be31a375) feat: add SOCKS5/HTTP proxy support via ~/.openusage/config.json by @zergzorg
- [bbbb6cc](https://github.com/robinebers/openusage/commit/bbbb6ccc1b29dec5c32bf1224317ebf41f91f9c4) Harden Windsurf quota parsing for missing and invalid balance data by @prayzey
- [c9ab800](https://github.com/robinebers/openusage/commit/c9ab800333e49793123456f4e72dd17aba44fb42) Handle missing Windsurf extra usage balance so quota still loads by @prayzey
- [d6ee9c6](https://github.com/robinebers/openusage/commit/d6ee9c68c13dddc650cfc78b4e26b3572489b35f) chore(deps): bump tokio from 1.50.0 to 1.51.0 in /src-tauri by @dependabot[bot]
- [857f537](https://github.com/robinebers/openusage/commit/857f537a243483acf98ccd9ea32e20b380c63823) fix: load factory auth from droid v2 store (#298) by @davidarny
- [625ae4e](https://github.com/robinebers/openusage/commit/625ae4e4b63a2b8597773aea94c3b86c8d45885f) refactor: update release process to push commits and tags before creating GitHub releases by @robinebers

## v0.6.12

### New Features
- Add local HTTP API for usage data ([#319](https://github.com/robinebers/openusage/pull/319)) by @robinebers
- Dynamic tray tooltip with usage percentages ([#314](https://github.com/robinebers/openusage/pull/314)) by @hearsilent
- Add release-tag skill for automated versioning and changelog generation by @robinebers

### Bug Fixes
- Fix new typescript v6 requirement by @robinebers
- Add runtime macOS version check for WKPreferences.inactiveSchedulingPolicy ([#322](https://github.com/robinebers/openusage/pull/322)) by @beznazwiska

### Chores
- Bump lucide-react from 0.577.0 to 1.7.0 ([#324](https://github.com/robinebers/openusage/pull/324)) by @dependabot
- Bump typescript from 5.9.3 to 6.0.2 ([#325](https://github.com/robinebers/openusage/pull/325)) by @dependabot
- Bump uuid from 1.22.0 to 1.23.0 in /src-tauri ([#323](https://github.com/robinebers/openusage/pull/323)) by @dependabot

---

### Changelog

**Full Changelog**: [v0.6.11...v0.6.12](https://github.com/robinebers/openusage/compare/v0.6.11...v0.6.12)

- [c1e7db8](https://github.com/robinebers/openusage/commit/c1e7db8725ad4d885198aa7c84cc885ae01e4edd) fix new typescript v6 requirement by @robinebers
- [97dde5b](https://github.com/robinebers/openusage/commit/97dde5bd7189cd95725568a935c3ba98058c2779) feat: add release-tag skill for automated versioning and changelog generation by @robinebers
- [ff0efa1](https://github.com/robinebers/openusage/commit/ff0efa1086f18f53405771d010fecdd8a8e20ffd) chore(deps): bump lucide-react from 0.577.0 to 1.7.0 by @dependabot
- [a3f7b7e](https://github.com/robinebers/openusage/commit/a3f7b7e53dbd9995b393ed0fafe36171cd4d876e) chore(deps-dev): bump typescript from 5.9.3 to 6.0.2 by @dependabot
- [4f7373f](https://github.com/robinebers/openusage/commit/4f7373f368a8d8147299a36c1be87b15873ee5bf) chore(deps): bump uuid from 1.22.0 to 1.23.0 in /src-tauri by @dependabot
- [4e152f7](https://github.com/robinebers/openusage/commit/4e152f7719f29a0e1936eb058df770138b306338) fix: add runtime macOS version check for WKPreferences.inactiveSchedulingPolicy by @beznazwiska
- [630e7dd](https://github.com/robinebers/openusage/commit/630e7dd0b3cdfd3d79e922a95286dd3d013d2292) feat: add local HTTP API for usage data by @robinebers
- [ddf73eb](https://github.com/robinebers/openusage/commit/ddf73eb3d3da8327ff2c22fc57761983039e11c4) feat(tooltip): dynamic tray tooltip with usage percentages by @hearsilent

## 0.6.11

### New Features
- Add in-app changelog ([#309](https://github.com/robinebers/openusage/pull/309)) by @hearsilent
- Add drag-to-reorder plugin icons in sidebar by @hearsilent

### Bug Fixes
- Refresh Windsurf quota cloud plugin ([#313](https://github.com/robinebers/openusage/pull/313)) by @robinebers
- Send real app version to credits API by @robinebers
- Fix reset tooltips to mirror display mode ([#297](https://github.com/robinebers/openusage/pull/297)) by @robinebers
- Preserve leading disabled plugin on reorder by @hearsilent
- Preserve disabled plugins when reordering by @hearsilent
- Fix test issue by @hearsilent

### Chores
- Update bun.lock by @robinebers
- Bump jsdom from 28.1.0 to 29.0.1 ([#312](https://github.com/robinebers/openusage/pull/312)) by @dependabot
- Bump tauri-nspanel in /src-tauri ([#311](https://github.com/robinebers/openusage/pull/311)) by @dependabot
- Update AGENTS.md to version 0.27 by @robinebers
- Update lucide-react lockfile by @robinebers
- Use next plist path in cloud mocks by @robinebers

---

### Changelog

**Full Changelog**: [v0.6.10...v0.6.11](https://github.com/robinebers/openusage/compare/v0.6.10...v0.6.11)

- [f5edf2a](https://github.com/robinebers/openusage/commit/f5edf2a) update bun.lock by @robinebers
- [3a66f32](https://github.com/robinebers/openusage/commit/3a66f32) chore(deps-dev): bump jsdom from 28.1.0 to 29.0.1 (#312) by @dependabot
- [0ba68d8](https://github.com/robinebers/openusage/commit/0ba68d8) chore(deps): bump tauri-nspanel in /src-tauri (#311) by @dependabot
- [11ce2d5](https://github.com/robinebers/openusage/commit/11ce2d5) fix: refresh Windsurf quota cloud plugin (#313) by @robinebers
- [0bfcaa3](https://github.com/robinebers/openusage/commit/0bfcaa3) feat: in-app changelog (#309) by @hearsilent
- [73fe349](https://github.com/robinebers/openusage/commit/73fe349) Update AGENTS.md to version 0.27 by @robinebers
- [459647c](https://github.com/robinebers/openusage/commit/459647c) build: update lucide-react lockfile by @robinebers
- [086ad7d](https://github.com/robinebers/openusage/commit/086ad7d) test(windsurf): use next plist path in cloud mocks by @robinebers
- [0c716fb](https://github.com/robinebers/openusage/commit/0c716fb) fix(windsurf): send real app version to credits API by @robinebers
- [0766afc](https://github.com/robinebers/openusage/commit/0766afc) Fix reset tooltips to mirror display mode (#297) by @robinebers
- [a71a4c1](https://github.com/robinebers/openusage/commit/a71a4c1) fix: preserve leading disabled plugin on reorder by @hearsilent
- [c84ba87](https://github.com/robinebers/openusage/commit/c84ba87) fix: preserve disabled plugins when reordering by @hearsilent
- [7ac86fb](https://github.com/robinebers/openusage/commit/7ac86fb) fix: test issue by @hearsilent
- [b1d290d](https://github.com/robinebers/openusage/commit/b1d290d) feat: add drag-to-reorder plugin icons in sidebar by @hearsilent

## 0.6.10

### New Features
- Add OpenCode Go plugin with tracking and limits ([#270](https://github.com/robinebers/openusage/pull/270)) by @praveenjuge
- Show Max 5x/20x tier in plan badge (claude) ([#284](https://github.com/robinebers/openusage/pull/284)) by @DiogoDuart3

### Bug Fixes
- Bump ccusage to v18.0.10 ([#295](https://github.com/robinebers/openusage/pull/295)) by @robinebers
- Count daily active usage more accurately ([#294](https://github.com/robinebers/openusage/pull/294)) by @robinebers
- Accept percent-only free usage payloads (cursor) ([#269](https://github.com/robinebers/openusage/pull/269)) by @davidarny
- Prefer auth.encrypted over auth.json (factory) ([#268](https://github.com/robinebers/openusage/pull/268)) by @sudoanmol

### Chores
- Bump lucide-react from 0.575.0 to 0.577.0 ([#276](https://github.com/robinebers/openusage/pull/276)) by @dependabot
- Bump @vitejs/plugin-react from 5.2.0 to 6.0.1 ([#290](https://github.com/robinebers/openusage/pull/290)) by @dependabot
- Bump uuid from 1.21.0 to 1.22.0 in /src-tauri ([#275](https://github.com/robinebers/openusage/pull/275)) by @dependabot
- Bump vite from 7.3.1 to 8.0.0 ([#289](https://github.com/robinebers/openusage/pull/289)) by @dependabot

---

### Changelog

**Full Changelog**: [v0.6.9...v0.6.10](https://github.com/robinebers/openusage/compare/v0.6.9...v0.6.10)

- [50f577f](https://github.com/robinebers/openusage/commit/50f577f) fix(ccusage): bump to v18.0.10 (#295) by @robinebers
- [78b5270](https://github.com/robinebers/openusage/commit/78b5270) fix(analytics): count daily active usage more accurately (#294) by @robinebers
- [2aaadf0](https://github.com/robinebers/openusage/commit/2aaadf0) feat(opencode-go): add OpenCode Go plugin with tracking and limits (#270) by @praveenjuge
- [7bfc51d](https://github.com/robinebers/openusage/commit/7bfc51d) fix(cursor): accept percent-only free usage payloads (#269) by @davidarny
- [54f7bac](https://github.com/robinebers/openusage/commit/54f7bac) chore(deps): bump lucide-react from 0.575.0 to 0.577.0 (#276) by @dependabot
- [5a475ab](https://github.com/robinebers/openusage/commit/5a475ab) chore(deps-dev): bump @vitejs/plugin-react from 5.2.0 to 6.0.1 (#290) by @dependabot
- [3477cdf](https://github.com/robinebers/openusage/commit/3477cdf) chore(deps): bump uuid from 1.21.0 to 1.22.0 in /src-tauri (#275) by @dependabot
- [b0900bc](https://github.com/robinebers/openusage/commit/b0900bc) chore(deps-dev): bump vite from 7.3.1 to 8.0.0 (#289) by @dependabot
- [5339e08](https://github.com/robinebers/openusage/commit/5339e08) feat(claude): show Max 5x/20x tier in plan badge (#284) by @DiogoDuart3
- [a04c8ee](https://github.com/robinebers/openusage/commit/a04c8ee) Merge pull request #268 from sudoanmol/fix/factory-auth-path-order by @sudoanmol
- [a6c3e30](https://github.com/robinebers/openusage/commit/a6c3e30) test(factory): add regression test for auth.encrypted preference over stale auth.json by @sudoanmol
- [526d6ca](https://github.com/robinebers/openusage/commit/526d6ca) fix(factory): prefer auth.encrypted over auth.json by @sudoanmol

## 0.6.8

### New Features
- Auto-detect MiniMax CN/global endpoint and show region label ([#230](https://github.com/robinebers/openusage/pull/230)) by @FrankieeW
- Add Total usage, Auto usage, API usage metrics for Cursor ([#226](https://github.com/robinebers/openusage/pull/226)) by @robinebers
- Restore bars mode and simplify menubar options ([#234](https://github.com/robinebers/openusage/pull/234)) by @robinebers

### Bug Fixes
- Update About dialog with contributor credits and green icon ([#240](https://github.com/robinebers/openusage/pull/240)) by @robinebers
- Clarify Claude extra usage metric by renaming label to "Extra usage spent" ([#239](https://github.com/robinebers/openusage/pull/239)) by @app/copilot-swe-agent
- Centralize ccusage version pinning and add bump command ([#238](https://github.com/robinebers/openusage/pull/238)) by @robinebers
- Compact loading skeleton and dedupe line grouping ([#228](https://github.com/robinebers/openusage/pull/228)) by @davidarny
- Harden PATH enrichment and add regression tests ([#220](https://github.com/robinebers/openusage/pull/220)) by @robinebers

### Chores
- Remove outdated note about Windows/Linux testing from README by @robinebers
- Update .gitignore to include .vscode and .conductor directories by @robinebers
- Remove deprecated VSCode extensions configuration file by @robinebers

### Changelog

**Full Changelog**: [v0.6.7...v0.6.8](https://github.com/robinebers/openusage/compare/v0.6.7...v0.6.8)

- [10635c6](https://github.com/robinebers/openusage/commit/10635c6) chore: bump version to 0.6.8 by @robinebers
- [9aa5371](https://github.com/robinebers/openusage/commit/9aa5371) fix(ui): update About dialog with contributor credits and green icon (#240) by @robinebers
- [903e6b2](https://github.com/robinebers/openusage/commit/903e6b2) feat(minimax): auto-detect CN/global endpoint and region label (#230) by @FrankieeW
- [7bd1383](https://github.com/robinebers/openusage/commit/7bd1383) Clarify Claude extra usage metric by renaming label to "Extra usage spent" (#239) by @app/copilot-swe-agent
- [208eb2d](https://github.com/robinebers/openusage/commit/208eb2d) fix(ccusage): centralize version pinning and add bump command (#238) by @robinebers
- [49b0b59](https://github.com/robinebers/openusage/commit/49b0b59) feat(cursor): add Total usage, Auto usage, API usage metrics (#226) by @robinebers
- [c768281](https://github.com/robinebers/openusage/commit/c768281) feat(tray): restore bars mode and simplify menubar options (#234) by @robinebers
- [e58837b](https://github.com/robinebers/openusage/commit/e58837b) test: raise coverage and enforce global 90% thresholds (#219) by @robinebers
- [28d9014](https://github.com/robinebers/openusage/commit/28d9014) fix(ui): compact loading skeleton and dedupe line grouping (#228) by @davidarny
- [240df4e](https://github.com/robinebers/openusage/commit/240df4e) chore: remove outdated note about Windows/Linux testing from README by @robinebers
- [1755ed3](https://github.com/robinebers/openusage/commit/1755ed3) chore: update .gitignore to include .vscode and .conductor directories by @robinebers
- [d06cdf3](https://github.com/robinebers/openusage/commit/d06cdf3) chore: remove deprecated VSCode extensions configuration file by @robinebers
- [35a921f](https://github.com/robinebers/openusage/commit/35a921f) fix(ccusage): harden PATH enrichment and add regression tests (#220) by @robinebers

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
