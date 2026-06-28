# Changelog

## v0.7.1-beta.1

### New Features
- Add GitHub Copilot usage provider ([#764](https://github.com/robinebers/openusage/pull/764)) by @robinebers
- Undo widget removal ([#603](https://github.com/robinebers/openusage/pull/771)) by @robinebers
- Price GLM 5.2 in the spend manifest ([#781](https://github.com/robinebers/openusage/pull/781)) by @robinebers
- Bring back provider quick-link buttons ([#596](https://github.com/robinebers/openusage/pull/779)) by @robinebers
- Per-provider Copy as Image card ([#762](https://github.com/robinebers/openusage/pull/778)) by @robinebers

### Bug Fixes
- Show "Not started" for unused 5-hour quota pools (Antigravity) ([#761](https://github.com/robinebers/openusage/pull/761)) by @robinebers

### Chores
- Bump github.com/sindresorhus/keyboardshortcuts ([#766](https://github.com/robinebers/openusage/pull/766)) by @dependabot
- Bump actions/checkout from 6 to 7 ([#765](https://github.com/robinebers/openusage/pull/765)) by @dependabot

---

### Changelog
**Full Changelog**: [v0.7.0...v0.7.1-beta.1](https://github.com/robinebers/openusage/compare/v0.7.0...v0.7.1-beta.1)

- [c74998a](https://github.com/robinebers/openusage/commit/c74998a6bc1f0e53855c936a36e3a2ef71a4df98) feat(copilot): add GitHub Copilot usage provider (#764) by @robinebers
- [7530469](https://github.com/robinebers/openusage/commit/75304694e84ed86b5e3cdc425e4c3fb24bc3b26c) fix(antigravity): show "Not started" for unused 5-hour quota pools (#761) by @robinebers
- [6c3d034](https://github.com/robinebers/openusage/commit/6c3d034a990bdb618d8a3ea7cab3d0c8002ac9d9) feat(customize): undo widget removal (#603) (#771) by @robinebers
- [f159788](https://github.com/robinebers/openusage/commit/f159788361fc29f6ee84ac722d8e087a327a4de9) feat(cursor): price GLM 5.2 in the spend manifest (#781) by @robinebers
- [bf7fa4d](https://github.com/robinebers/openusage/commit/bf7fa4d6e89fc6a34e11f02f65b645257d985a02) feat(providers): bring back provider quick-link buttons (#596) (#779) by @robinebers
- [78ef4a7](https://github.com/robinebers/openusage/commit/78ef4a70c368f847302ebf71da296445146271eb) feat(share): per-provider Copy as Image card (#762) (#778) by @robinebers
- [c148a4c](https://github.com/robinebers/openusage/commit/c148a4c35c929fb8fd3d0363181f625f71d3418a) chore(deps): bump github.com/sindresorhus/keyboardshortcuts (#766) by @dependabot
- [e62400d](https://github.com/robinebers/openusage/commit/e62400de6ce09eeb911013721ac15705815e3771) chore(deps): bump actions/checkout from 6 to 7 (#765) by @dependabot

## v0.7.0

**A brand-new OpenUsage.** The app has been rebuilt from the ground up to be faster, lighter, and feel right at home on your Mac.

> **Coming from an earlier version?** This is a fresh start. Your usage and sign-ins are still read straight from your machine — but the app and its look are all new.

### Highlights

- **Rebuilt for Mac** — quicker to open, lighter to run, and a clean, modern look. Runs on macOS Sequoia and later, on both Apple Silicon and Intel Macs.
- **More providers** — Claude, Codex, Cursor, Grok, Devin, and Antigravity, all in one place.
- **Usage trends** — a quick sparkline of recent usage for Claude, Codex, Cursor, and Grok.
- **Pacing** — see whether you're ahead or behind, with a "Limit in 3h 45m" estimate and an optional always-on view.
- **Clearer spend** — cost and tokens shown side by side, with a clean "$0.00 · 0 tokens" when there's nothing to show yet.
- **Codex limit resets** — see when your limits refresh, right in the menu bar and popover.
- **Make it yours** — resize the panel, expand extra metrics, reorder providers, pin your favorites to the menu bar, and right-click for quick actions.
- **Private by default** — optional, anonymous usage and crash reporting you can turn off anytime.

### New in this release

- **Your settings now stick** — updating no longer resets your layout, pins, and preferences.
- **More reliable Claude sign-in** — steadier connection and clearer messages when something needs attention.
- **Cursor** — spend is temporarily hidden while Cursor's own usage data is delayed, so you don't see misleading numbers.
- Smaller fixes and polish throughout.

---

### Changelog

**Full Changelog**: [v0.6.28...v0.7.0](https://github.com/robinebers/openusage/compare/v0.6.28...v0.7.0)

Thanks to @robinebers, @davidarny, and @validatedev.

## v0.7.0-beta.16

### New Features
- Anonymous opt-out PostHog usage analytics ([#735](https://github.com/robinebers/openusage/pull/735)) by @robinebers
- Anonymous crash + uncaught-exception reporting ([#739](https://github.com/robinebers/openusage/pull/739)) by @robinebers
- Add Antigravity provider ([#745](https://github.com/robinebers/openusage/pull/745)) by @robinebers

### Bug Fixes
- Remove discontinued Sonnet weekly limit ([#744](https://github.com/robinebers/openusage/pull/744)) by @robinebers
- ccusage: local-time day buckets, no fabricated $0.00 for unreported days ([#746](https://github.com/robinebers/openusage/pull/746)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.15...v0.7.0-beta.16](https://github.com/robinebers/openusage/compare/v0.7.0-beta.15...v0.7.0-beta.16)

- [9d732c7](https://github.com/robinebers/openusage/commit/9d732c754e30e2105885214d4aae60c0c51a969d) fix(ccusage): local-time day buckets, no fabricated $0.00 for unreported days (#746) by @robinebers
- [e5cf2f7](https://github.com/robinebers/openusage/commit/e5cf2f7cc85c2cd278d6ec96d942d626eff33ba7) fix(claude): remove discontinued Sonnet weekly limit (#744) by @robinebers
- [dc2a80d](https://github.com/robinebers/openusage/commit/dc2a80dcd4bc22a12d2319d69d4b99e0cf4a2967) feat(antigravity): add Antigravity provider (#745) by @robinebers
- [67e546b](https://github.com/robinebers/openusage/commit/67e546b77063ac40328bed68e6394923038b2a66) feat(telemetry): anonymous crash + uncaught-exception reporting (#739) by @robinebers
- [c344732](https://github.com/robinebers/openusage/commit/c34473212c85812a8dd65c596badeeb22eb09fe7) feat(telemetry): anonymous opt-out PostHog usage analytics (#735) by @robinebers
- [1765ba7](https://github.com/robinebers/openusage/commit/1765ba7499cdb15b2ad1ecfa95e440f3475ea447) docs: simplify release-swift skill and document release channels by @robinebers
- [57d210a](https://github.com/robinebers/openusage/commit/57d210a9b0e4d9ec242a9745b110aa36d544c34a) chore: preserve Tauri updater manifest during Swift flip by @robinebers
- [4d1158b](https://github.com/robinebers/openusage/commit/4d1158b3431505864cb9178abe9b8e52e1872dda) chore: prepare Swift branch cutover by @robinebers
- [a6d6050](https://github.com/robinebers/openusage/commit/a6d605069a729e1f1b8f2848f89757d332a4f8ab) chore: add macOS agent skills and skills-lock by @robinebers

---

## v0.7.0-beta.15

### New Features
- feat(popover): coordinated-morph auto-resize for the menu-bar panel ([#730](https://github.com/robinebers/openusage/pull/730)) by @robinebers
- feat(popover): System Settings grouped surface + Settings-primary footer ([#726](https://github.com/robinebers/openusage/pull/726)) by @robinebers

### Bug Fixes
- Centered Customize/Settings header + per-provider reset menu ([#734](https://github.com/robinebers/openusage/pull/734)) by @robinebers
- fix(settings): rename Startup→General, Menu Style→Icon Style ([#733](https://github.com/robinebers/openusage/pull/733)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.14...v0.7.0-beta.15](https://github.com/robinebers/openusage/compare/v0.7.0-beta.14...v0.7.0-beta.15)

- [bb8876a](https://github.com/robinebers/openusage/commit/bb8876aeae698bd696ee67bdc31d0a6ce967f96e) Centered Customize/Settings header + per-provider reset menu (#729) (#734) by @robinebers
- [b41f139](https://github.com/robinebers/openusage/commit/b41f1396a1976856831b6d59fb13e0ac311442ec) fix(settings): rename Startup→General, Menu Style→Icon Style (#733) by @robinebers
- [0ad7edc](https://github.com/robinebers/openusage/commit/0ad7edcdea4f81d9ef47c5357ccda70b30922a41) feat(popover): coordinated-morph auto-resize for the menu-bar panel (#730) by @robinebers
- [098777b](https://github.com/robinebers/openusage/commit/098777be0fc83bb14ebe1265a266542b5995b31d) feat(popover): System Settings grouped surface + Settings-primary footer (#726) by @robinebers

---

## v0.7.0-beta.14

### New Features
- feat(popover): opaque body + content-aware Liquid Glass footer/header ([#724](https://github.com/robinebers/openusage/pull/724)) by @robinebers

### Bug Fixes
- fix(build): stamp linked SDK 26 so AppKit renders modern Liquid Glass controls ([#725](https://github.com/robinebers/openusage/pull/725)) by @robinebers
- Fix Cursor credits and extra usage balances ([#723](https://github.com/robinebers/openusage/pull/723)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.13...v0.7.0-beta.14](https://github.com/robinebers/openusage/compare/v0.7.0-beta.13...v0.7.0-beta.14)

- [f72e514](https://github.com/robinebers/openusage/commit/f72e514235375859f0f6f96052d48f2289c19e99) fix(build): stamp linked SDK 26 so AppKit renders modern Liquid Glass controls (#725) by @robinebers
- [3760233](https://github.com/robinebers/openusage/commit/376023305f7ee76a8ba8fb3dcc8e6f929bd740a8) feat(popover): opaque body + content-aware Liquid Glass footer/header (#724) by @robinebers
- [f8e7ff7](https://github.com/robinebers/openusage/commit/f8e7ff779d2e288ac0454915b2c3473f969a7cb7) Fix Cursor credits and extra usage balances (#723) by @robinebers

## v0.7.0-beta.13

> Heads up: while OpenUsage is in Early Access, updating to a new beta resets all settings — layout, pins, preferences, and the menu-bar shortcut — back to defaults. Betas ship no settings migrations, so each one starts from a clean slate.

### New Features
- Reset all settings to defaults on every beta update (no migrations during Early Access) by @robinebers
- Liquid Glass split button in the footer ([#722](https://github.com/robinebers/openusage/pull/722)) by @robinebers
- Add expandable dashboard metrics by @robinebers
- Show "Not started" for unused Codex/Claude sessions; simplify pace ticks ([#719](https://github.com/robinebers/openusage/pull/719)) by @robinebers
- Make the menu-bar panel user-resizable ([#717](https://github.com/robinebers/openusage/pull/717)) by @robinebers
- Remove the Reduce Transparency setting; the popover keeps its Liquid Glass surface ([#718](https://github.com/robinebers/openusage/pull/718)) by @robinebers

### Bug Fixes
- Render tooltips above the popover and wrap long text ([#715](https://github.com/robinebers/openusage/pull/715)) by @davidarny
- Fail loudly on malformed custom OAuth URL instead of crashing ([#700](https://github.com/robinebers/openusage/pull/700)) by @robinebers
- Try all Claude credential sources with fallback on auth failure ([#694](https://github.com/robinebers/openusage/pull/694)) by @robinebers
- Restrict Usage Trend hover to the mini chart, not the label ([#716](https://github.com/robinebers/openusage/pull/716)) by @robinebers
- Fix pace marker placement: true even-pace line in both views ([#714](https://github.com/robinebers/openusage/pull/714)) by @robinebers
- Refine row/provider right-click menus + footer pull-down button ([#713](https://github.com/robinebers/openusage/pull/713)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.12...v0.7.0-beta.13](https://github.com/robinebers/openusage/compare/v0.7.0-beta.12...v0.7.0-beta.13)

- [2d47fb4](https://github.com/robinebers/openusage/commit/2d47fb4164ee9b0559d4f5f6f631cd8bbe257f18) feat(settings): reset all settings on beta version changes by @robinebers
- [a234aeb](https://github.com/robinebers/openusage/commit/a234aeb8bac97df99f3f9c025e280a45a6ff3f61) fix(popover): restore translucent footer with behind-window glass by @robinebers
- [730ffa7](https://github.com/robinebers/openusage/commit/730ffa7d0435675edd63695fc4ebc026b3f7824b) feat(popover): Liquid Glass split button in the footer (#722) by @robinebers
- [d93a745](https://github.com/robinebers/openusage/commit/d93a7451ebd05164eb79c8229aaec6d3ddfd9a44) Add expandable dashboard metrics by @robinebers
- [1c13b7d](https://github.com/robinebers/openusage/commit/1c13b7de01ff9b5394a29fe1804be6a42b39bd08) feat(pacing): show "Not started" for unused Codex/Claude sessions; simplify pace ticks (#719) by @robinebers
- [6faaf25](https://github.com/robinebers/openusage/commit/6faaf252379751423f68b378fa9379ad9b0eb64c) feat(popover): solid opaque surface; drop Reduce Transparency toggle (#718) by @robinebers
- [4aca0ba](https://github.com/robinebers/openusage/commit/4aca0ba83b83a39c7c17f1f52a3bd10e5dce040a) fix(tooltip): render above popover and wrap long text (#715) by @davidarny
- [11d673a](https://github.com/robinebers/openusage/commit/11d673a6f859840d1f96e83f67ca76443eb5f567) fix(claude): fail loudly on malformed custom OAuth URL instead of crashing (#700) by @robinebers
- [39ad9f3](https://github.com/robinebers/openusage/commit/39ad9f32a1d39846c3c735874921ccedd1d98855) fix(claude): try all credential sources with fallback on auth failure (#687) (#694) by @robinebers
- [cf8ee7b](https://github.com/robinebers/openusage/commit/cf8ee7b2f6ef39ebaec06c7898b64ffdca7b3415) Restrict usage trend hover to the mini chart, not the label (#716) by @robinebers
- [336821d](https://github.com/robinebers/openusage/commit/336821d0e26841c3d9b69f704671f65b9782767b) feat(popover): make the menu-bar panel user-resizable (#717) by @robinebers
- [dea1d2d](https://github.com/robinebers/openusage/commit/dea1d2d76ffbd093e1380d9b1f39623abcac334b) Fix pace marker placement: true even-pace line in both views (#714) by @robinebers
- [7937806](https://github.com/robinebers/openusage/commit/79378065afab901700a202799462330621efdf48) Refine row/provider right-click menus + footer pull-down button (#713) by @robinebers

## v0.7.0-beta.12

### New Features
- Add "Always Show Pacing" setting for on-track meters ([#707](https://github.com/robinebers/openusage/pull/707)) by @robinebers
- Extend Usage Trend sparkline to Cursor and Grok ([#698](https://github.com/robinebers/openusage/pull/698)) by @robinebers
- Default Reduce Transparency on for readability ([#691](https://github.com/robinebers/openusage/pull/691)) by @robinebers
- Add provider-header drag handle ([#677](https://github.com/robinebers/openusage/pull/677)) by @robinebers
- Add Usage Trend sparkline for Claude and Codex ([#669](https://github.com/robinebers/openusage/pull/669)) by @davidarny

### Bug Fixes
- Fix metric value tooltips ([#710](https://github.com/robinebers/openusage/pull/710)) by @robinebers
- Reorder default metric customization ([#711](https://github.com/robinebers/openusage/pull/711)) by @robinebers
- Fix Codex session usage percent ([#708](https://github.com/robinebers/openusage/pull/708)) by @robinebers
- Fix menu bar metric units ([#709](https://github.com/robinebers/openusage/pull/709)) by @robinebers
- Clamp quota percent meters to 0–100 ([#706](https://github.com/robinebers/openusage/pull/706)) by @robinebers
- Scope snapshot freshness to the running session ([#702](https://github.com/robinebers/openusage/pull/702)) by @robinebers
- Top-leading back nav on Customize/Settings; unify Customize header ([#699](https://github.com/robinebers/openusage/pull/699)) by @robinebers
- Unify Extra Usage number formatting via MetricFormatter ([#695](https://github.com/robinebers/openusage/pull/695)) by @robinebers
- Restore estimate note on spend-row ⓘ tooltip ([#692](https://github.com/robinebers/openusage/pull/692)) by @robinebers

### Refactor
- Streamline Swift codebase for release (incl. #690) ([#693](https://github.com/robinebers/openusage/pull/693)) by @robinebers

### Chores
- Document AGENTS.md as agent instruction source by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0-beta.11...v0.7.0-beta.12](https://github.com/robinebers/openusage/compare/v0.7.0-beta.11...v0.7.0-beta.12)

- [ab503ec](https://github.com/robinebers/openusage/commit/ab503ec7d6fbeb2bdc7ec7b48056b8708da7a292) fix metric value tooltips (#710) by @robinebers
- [0738d38](https://github.com/robinebers/openusage/commit/0738d386c183b0b789502fffee319d35a55d64ba) Reorder default metric customization (#711) by @robinebers
- [a4cba27](https://github.com/robinebers/openusage/commit/a4cba27a11acd9cec7148eaa6ecb4d1b6705b964) Fix Codex session usage percent (#708) by @robinebers
- [9afa03f](https://github.com/robinebers/openusage/commit/9afa03f6be6b64112b6664aaa42dfbda2460b393) Document AGENTS.md as agent instruction source by @robinebers
- [e40f37d](https://github.com/robinebers/openusage/commit/e40f37d68b1eb9c1c4c62c376b537bc450faca9c) Fix menu bar metric units (#709) by @robinebers
- [da039fe](https://github.com/robinebers/openusage/commit/da039fe8ba10a7ed6cf71a08d73c1e27bc8647f1) feat(dashboard): add "Always Show Pacing" setting for on-track meters (#685) (#707) by @robinebers
- [3664118](https://github.com/robinebers/openusage/commit/36641184e2808195a9882433404d0eae20fc6b70) fix(metrics): clamp quota percent meters to 0–100 (#703) (#706) by @robinebers
- [5faf25c](https://github.com/robinebers/openusage/commit/5faf25c311ca230e1c20d869606ce8bdc4b17de1) fix(cache): scope snapshot freshness to the running session (#697) (#702) by @robinebers
- [f338734](https://github.com/robinebers/openusage/commit/f3387349e1c722b5b321e9ddc406ada17230600a) Top-leading back nav on Customize/Settings; unify Customize header (#699) by @robinebers
- [b545135](https://github.com/robinebers/openusage/commit/b545135d862faaf7f150d49a605a969bb13730ca) feat(dashboard): extend Usage Trend sparkline to Cursor and Grok (#688) (#698) by @robinebers
- [0da519b](https://github.com/robinebers/openusage/commit/0da519bb4a8e019922de37b4576d4d23183ecede) fix(format): unify Extra Usage number formatting via MetricFormatter (#658) (#695) by @robinebers
- [f9a047d](https://github.com/robinebers/openusage/commit/f9a047d84a082642e044759fcbc51bec533aa6b7) refactor: streamline Swift codebase for release (incl. #690) (#693) by @robinebers
- [bac1132](https://github.com/robinebers/openusage/commit/bac1132afe7ef795c7aad5337ab29a2a1ebd3e03) fix(dashboard): restore estimate note on spend-row ⓘ tooltip (#683) (#692) by @robinebers
- [260542a](https://github.com/robinebers/openusage/commit/260542a5d8f8df86b1411252ef9a3e143ce1a78b) feat(settings): default Reduce Transparency on for readability (#691) by @robinebers
- [8836031](https://github.com/robinebers/openusage/commit/8836031f238b977158c1099bc230a6bd9fae5e3d) feat(dashboard): add provider-header drag handle (#677) by @robinebers
- [be801f1](https://github.com/robinebers/openusage/commit/be801f134bcdf1585e12678855bb15ed477ebe23) feat(dashboard): add Usage Trend sparkline for Claude and Codex (#669) by @davidarny

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
