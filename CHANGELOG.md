# Changelog

## v0.7.0-beta.11

### New Features
- feat(codex): show rate-limit reset credits with per-credit expiry ([#675](https://github.com/robinebers/openusage/pull/675)) by @robinebers
- feat(menubar): add right-click context menu with Settings and Quit ([#671](https://github.com/robinebers/openusage/pull/671)) by @davidarny

### Bug Fixes
- fix(popover): clear stray focus ring on open, click-away, and close ([#674](https://github.com/robinebers/openusage/pull/674)) by @davidarny
- fix(dev): fall back to the prebuilt icon when actool fails in build_and_run.sh ([#673](https://github.com/robinebers/openusage/pull/673)) by @davidarny
- fix(dashboard): flag stale snapshots with an "Updated X ago" hint ([#668](https://github.com/robinebers/openusage/pull/668)) by @davidarny
- fix(refresh): stop runaway refresh storm that drops the menu-bar item ([#665](https://github.com/robinebers/openusage/pull/665)) by @robinebers
- hardening: fix local-API crash + MainActor freeze; replace silent fallbacks with loud failures ([#667](https://github.com/robinebers/openusage/pull/667)) by @robinebers

### Chores
- perf(refresh): cache ccusage runner resolution and snapshot blob ([#672](https://github.com/robinebers/openusage/pull/672)) by @davidarny

---

### Changelog
**Full Changelog**: [v0.7.0-beta.10...v0.7.0-beta.11](https://github.com/robinebers/openusage/compare/v0.7.0-beta.10...v0.7.0-beta.11)

- [2082b39](https://github.com/robinebers/openusage/commit/2082b39111dc94af77bdd7eaaadd56b857bc5f88) feat(codex): show rate-limit reset credits with per-credit expiry (#675) by @robinebers
- [bf66276](https://github.com/robinebers/openusage/commit/bf66276b6460491b691ab82f115f05f6dcc9a672) perf(refresh): cache ccusage runner resolution and snapshot blob (#672) by @davidarny
- [64e2d13](https://github.com/robinebers/openusage/commit/64e2d130c96d7e9f3457ca11c211e156f9c7f728) fix(popover): clear stray focus ring on open, click-away, and close (#674) by @davidarny
- [b4d828a](https://github.com/robinebers/openusage/commit/b4d828a21ed40fdba84ed621873a3c9d99769103) fix(dev): fall back to the prebuilt icon when actool fails in build_and_run.sh (#673) by @davidarny
- [03782a7](https://github.com/robinebers/openusage/commit/03782a7b3dc27db062eae041a9d0167921541fd9) feat(menubar): add right-click context menu with Settings and Quit (#671) by @davidarny
- [7769bfc](https://github.com/robinebers/openusage/commit/7769bfc96c27ff993bf6a5778a376391cfea56c2) fix(dashboard): flag stale snapshots with an "Updated X ago" hint (#582) (#668) by @davidarny
- [b05f794](https://github.com/robinebers/openusage/commit/b05f794e7de98fa723d987a4df434ab31a6e3909) fix(refresh): stop runaway refresh storm that drops the menu-bar item (#665) by @robinebers
- [f1afaa8](https://github.com/robinebers/openusage/commit/f1afaa846ce1d3e290c159bd50c2b6ba834dfa04) hardening: fix local-API crash + MainActor freeze; replace silent fallbacks with loud failures (#667) by @robinebers

---

## v0.7.0-beta.10

### New Features
- feat(footer): fold Settings + Check for Updates into the More menu ([#657](https://github.com/robinebers/openusage/pull/657)) by @robinebers
- feat(updates): check for updates hourly instead of daily ([#655](https://github.com/robinebers/openusage/pull/655)) by @robinebers

### Bug Fixes
- fix(tooltip): reveal hover tooltips after a short delay, not the slow native one ([#660](https://github.com/robinebers/openusage/pull/660)) by @validatedev
- fix(spend): show "$0.00 · 0 tokens" for zero-usage periods, add tokens unit ([#656](https://github.com/robinebers/openusage/pull/656)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.9...v0.7.0-beta.10](https://github.com/robinebers/openusage/compare/v0.7.0-beta.9...v0.7.0-beta.10)

- [4f02053](https://github.com/robinebers/openusage/commit/4f02053df0ba6f9a8380a1cb87bf1698dadf2d59) fix(tooltip): reveal hover tooltips after a short delay, not the slow native one (#660) by @validatedev
- [040c511](https://github.com/robinebers/openusage/commit/040c5115ea5fbaab45b14b68838b3ea52d51ce1c) feat(footer): fold Settings + Check for Updates into the More menu (#657) by @robinebers
- [c436284](https://github.com/robinebers/openusage/commit/c436284e91b57432787cdb5683c4a9909eb85991) fix(spend): show "$0.00 · 0 tokens" for zero-usage periods, add tokens unit (#656) by @robinebers
- [2a9cf92](https://github.com/robinebers/openusage/commit/2a9cf929a6c8a79831d948cbefa000a99c87e4d1) feat(updates): check for updates hourly instead of daily (#655) by @robinebers

---

## v0.7.0-beta.9

### New Features
- Grok local spend tiles + unify spend tiles across providers ([#650](https://github.com/robinebers/openusage/pull/650)) by @robinebers

### Bug Fixes
- Host the dashboard in a key-capable NSPanel (reliable Esc/Return) ([#652](https://github.com/robinebers/openusage/pull/652)) by @robinebers
- Unify popover max height across Customize and Settings ([#651](https://github.com/robinebers/openusage/pull/651)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.8...v0.7.0-beta.9](https://github.com/robinebers/openusage/compare/v0.7.0-beta.8...v0.7.0-beta.9)

- [b6c6fcc](https://github.com/robinebers/openusage/commit/b6c6fccc3740063626f4a25b7cacd90376419ed7) fix(popover): host the dashboard in a key-capable NSPanel (reliable Esc/Return) (#652) by @robinebers
- [849862f](https://github.com/robinebers/openusage/commit/849862f4650a680d2b15bc63b7fd0244a58df9b2) fix: unify popover max height across Customize and Settings (#591) (#651) by @robinebers
- [210a395](https://github.com/robinebers/openusage/commit/210a39552b1af7e091288efd21a04a707cf2137c) feat: Grok local spend tiles + unify spend tiles across providers (#646) (#650) by @robinebers

## v0.7.0-beta.8

### New Features
- Split spend into cost/tokens, carry raw metric values (#641, #647) by @robinebers

## v0.7.0-beta.7

### New Features
- Show Codex rate limit resets in the tray and popover ([#638](https://github.com/robinebers/openusage/pull/638)) by @robinebers
- Collapse the footer Customize button into a More menu ([#640](https://github.com/robinebers/openusage/pull/640)) by @robinebers
- Label the pace run-out time as "Limit in 3h 45m" ([#643](https://github.com/robinebers/openusage/pull/643)) by @robinebers
- Show a numeric projection in pace meter tooltips at reset ([#644](https://github.com/robinebers/openusage/pull/644)) by @robinebers

### Bug Fixes
- Resolve npx/npm/pnpm/yarn ccusage runners, not just bunx ([#643](https://github.com/robinebers/openusage/pull/643)) by @robinebers
- Follow nvm alias indirection when locating the ccusage runner ([#643](https://github.com/robinebers/openusage/pull/643)) by @robinebers
- Unify the Codex rate-limit-resets value across tray and popover ([#638](https://github.com/robinebers/openusage/pull/638)) by @robinebers
- Promote a ~0% projected-spare pace meter to red, not amber ([#639](https://github.com/robinebers/openusage/pull/639)) by @robinebers
- Anchor the footer More menu to a flipped view ([#640](https://github.com/robinebers/openusage/pull/640)) by @robinebers
- Guard against a second app instance (duplicate menu-bar icon) ([#637](https://github.com/robinebers/openusage/pull/637)) by @robinebers
- Use a deterministic lowest-PID tie-break in the single-instance guard ([#637](https://github.com/robinebers/openusage/pull/637)) by @robinebers

## v0.7.0-beta.6

### New Features
- Add Reduce Transparency setting for readability ([#629](https://github.com/robinebers/openusage/pull/629)) by @robinebers
- Drop global pin cap, keep two per provider ([#630](https://github.com/robinebers/openusage/pull/630)) by @robinebers

### Bug Fixes
- Only draw card border/frost when Reduce Transparency is on by @robinebers
- Enlarge header provider glyph to match the menu-bar strip by @robinebers

### Chores
- Align README with per-provider pin limit by @robinebers

## v0.7.0-beta.5

### New Features
- Build a universal binary so the app runs natively on both Apple Silicon and Intel Macs by @robinebers
- Support macOS 15 (Sequoia) and later, not only Tahoe ([#623](https://github.com/robinebers/openusage/pull/623)) by @robinebers

### Bug Fixes
- Enlarge provider glyphs in the menu-bar Text strip ([#627](https://github.com/robinebers/openusage/pull/627)) by @robinebers

### Chores
- Drop the unworkable macos-15 CI verify leg ([#623](https://github.com/robinebers/openusage/pull/623)) by @robinebers

## v0.7.0-beta.4

### Bug Fixes
- Show the full version, including the beta tag, in both the updater prompt and the app footer so they match by @robinebers

### Chores
- Add hero screenshot to README by @robinebers

---

### Changelog

**Full Changelog**: [v0.7.0-beta.3...v0.7.0-beta.4](https://github.com/robinebers/openusage/compare/v0.7.0-beta.3...v0.7.0-beta.4)

- [763306b](https://github.com/robinebers/openusage/commit/763306b) fix(version): show the full version (incl. -beta.N) in Sparkle and the app by @robinebers
- [a82e8b3](https://github.com/robinebers/openusage/commit/a82e8b3) docs: add hero screenshot to README by @robinebers

## v0.7.0-beta.3

### New Features
- Port the Tauri debug-logging system to the native app ([#615](https://github.com/robinebers/openusage/pull/615)) by @robinebers

### Bug Fixes
- Fix white flicker on screen switches with an offset pager ([#614](https://github.com/robinebers/openusage/pull/614)) by @robinebers
- Fix Codex/Devin usage bugs ([#612](https://github.com/robinebers/openusage/pull/612)) by @robinebers

### Refactor
- Settings: drop Refresh Every, move Style into Appearance as Menu Style ([#613](https://github.com/robinebers/openusage/pull/613)) by @robinebers
- Remove dead code, fix stale comments, dedupe HTTP status guard ([#619](https://github.com/robinebers/openusage/pull/619)) by @robinebers
- Remove dead code, DRY duplication, hot-path allocations ([#610](https://github.com/robinebers/openusage/pull/610)) by @robinebers

### Chores
- Add rollout guardrails, rename release skill to release-swift, show full version in app ([#621](https://github.com/robinebers/openusage/pull/621)) by @robinebers
- Remove dead self-referential links and screenshot placeholders ([#618](https://github.com/robinebers/openusage/pull/618)) by @robinebers
- Run dev build in place instead of installing a Preview app by @robinebers

---

### Changelog

**Full Changelog**: [v0.7.0-beta.2...v0.7.0-beta.3](https://github.com/robinebers/openusage/compare/v0.7.0-beta.2...v0.7.0-beta.3)

- [c80b034](https://github.com/robinebers/openusage/commit/c80b034) feat(logging): port the Tauri debug-logging system to the native app by @robinebers
- [9c7d95e](https://github.com/robinebers/openusage/commit/9c7d95e) Fix white flicker on screen switches with an offset pager (#614) by @robinebers
- [250b278](https://github.com/robinebers/openusage/commit/250b278) Fix Codex/Devin usage bugs; cut dead code, DRY dup, stale docs by @robinebers
- [da7c69c](https://github.com/robinebers/openusage/commit/da7c69c) Settings: drop Refresh Every, move Style into Appearance as Menu Style by @robinebers
- [524e07e](https://github.com/robinebers/openusage/commit/524e07e) refactor: remove dead code, fix stale comments, dedupe HTTP status guard by @robinebers
- [8bdaf61](https://github.com/robinebers/openusage/commit/8bdaf61) Refactor: remove dead code, DRY duplication, hot-path allocations by @robinebers
- [c44247a](https://github.com/robinebers/openusage/commit/c44247a) chore: add rollout guardrails, rename release skill, show full version by @robinebers
- [6a9645d](https://github.com/robinebers/openusage/commit/6a9645d) docs: remove dead self-referential links and screenshot placeholders by @robinebers
- [0ea6b97](https://github.com/robinebers/openusage/commit/0ea6b97) Run dev build in place instead of installing a Preview app by @robinebers
