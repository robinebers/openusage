# Changelog

## v0.7.6-beta.2

### Bug Fixes
- Fix Claude and Codex token cost calculations, including Codex fast-tier pricing from session logs ([#995](https://github.com/robinebers/openusage/pull/995)) by @validatedev

### Chores
- Keep inactive issues open for 30 days before warning ([#998](https://github.com/robinebers/openusage/pull/998)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.6-beta.1...v0.7.6-beta.2](https://github.com/robinebers/openusage/compare/v0.7.6-beta.1...v0.7.6-beta.2)

- [be6e3d7](https://github.com/robinebers/openusage/commit/be6e3d733b4e57fa9ff31f6cf453d2ca2b25fedb) Merge pull request #998 from robinebers/cursor/cea9ec49 by @robinebers
- [e145e7a](https://github.com/robinebers/openusage/commit/e145e7a40f7448bb2722dc7cec225d33e7f871b0) chore(stale): keep inactive issues open for 30 days before warning by @robinebers
- [a0569bd](https://github.com/robinebers/openusage/commit/a0569bd13222b44e0907bac31897a0348b4ed0a4) Merge pull request #995 from robinebers/fix/token-cost-calculation-disperancies by @validatedev
- [cfdfdd0](https://github.com/robinebers/openusage/commit/cfdfdd08723bea3e7e4f5ac225b972f331b87771) fix: price Codex fast tier per session from rollout logs, not config.toml by @robinebers
- [0d0136d](https://github.com/robinebers/openusage/commit/0d0136d089936f381e5675bb468f1506d44838ce) fix: handle persisted Claude print usage and Codex fast aliases by @validatedev
- [bfb325c](https://github.com/robinebers/openusage/commit/bfb325c802ae018a3f61e35af3e70a3ab3e23fcc) fix: correct token cost calculations by @validatedev

## v0.7.6-beta.1

### New Features
- Read the existing Claude Desktop login safely as a read-only fallback ([#962](https://github.com/robinebers/openusage/pull/962)) by @robinebers
- Sync usage history across Macs with iCloud ([#984](https://github.com/robinebers/openusage/pull/984)) by @robinebers
- Add a machine-readable limits API and global `openusage` command ([#982](https://github.com/robinebers/openusage/pull/982)) by @robinebers
- Add hover-revealed screenshot copying to provider headers ([#989](https://github.com/robinebers/openusage/pull/989)) by @robinebers

### Bug Fixes
- Restore Cursor Enterprise included-request and on-demand usage ([#986](https://github.com/robinebers/openusage/pull/986)) by @iicdii
- Keep Sparkle updater windows in the foreground during manual updates ([#985](https://github.com/robinebers/openusage/pull/985)) by @robinebers
- Follow symlinked log directories when scanning local usage ([#973](https://github.com/robinebers/openusage/pull/973)) by @robinebers
- Recognize Cursor Grok 4.5 usage slugs ([#981](https://github.com/robinebers/openusage/pull/981)) by @robinebers

### Chores
- Ignore the `.build-test` directory by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.5...v0.7.6-beta.1](https://github.com/robinebers/openusage/compare/v0.7.5...v0.7.6-beta.1)

- [47cc6c7](https://github.com/robinebers/openusage/commit/47cc6c7f5d47025223c9f865dd3715da8820b02b) Merge pull request #962 from robinebers/cursor/5daa197a by @robinebers
- [a305236](https://github.com/robinebers/openusage/commit/a305236ea045d3b0296fb6d0eb38dfef3161ac28) Merge pull request #985 from robinebers/codex/fix-sparkle-update-focus by @robinebers
- [4cb0841](https://github.com/robinebers/openusage/commit/4cb084146cbb6a7932a6accadfa0cb8c28acba3a) fix(claude): try Desktop before environment fallback by @robinebers
- [09ef91c](https://github.com/robinebers/openusage/commit/09ef91c6c6e2bb74d1f8ce044652d64b580bbfc7) Merge pull request #986 from iicdii/fix/cursor-enterprise-usage by @robinebers
- [17ec2b9](https://github.com/robinebers/openusage/commit/17ec2b92ec4d7c0b99227d2c737d6aaf66534eab) Merge pull request #989 from robinebers/codex/provider-header-copy-feedback by @robinebers
- [71c7694](https://github.com/robinebers/openusage/commit/71c76947f8d44f5b4c1187e3743a7d752ce3c949) Refine provider header copy controls by @robinebers
- [3ac257c](https://github.com/robinebers/openusage/commit/3ac257c6dda8bfcefe21bf71d10e2aa9aac001a6) fix(claude): pick Desktop token by client/scope rank, not max expiry by @robinebers
- [1e65178](https://github.com/robinebers/openusage/commit/1e65178b60a120d36e0b0304e140831890a8bd73) feat: read Claude Desktop login safely by @robinebers
- [d514522](https://github.com/robinebers/openusage/commit/d5145223aed723ccfe76f179c05099484da1aec5) docs: add Cursor Enterprise live screenshot by @iicdii
- [022286f](https://github.com/robinebers/openusage/commit/022286fc317ff25dca19e48badd6007beb71ad86) fix(cursor): show enterprise included and on-demand usage by @iicdii
- [aa51755](https://github.com/robinebers/openusage/commit/aa517553cb506ff6e8e279aca98bcc1ee1192ae3) Merge remote-tracking branch `origin/main` into updater-focus work by @robinebers
- [a8c8fa5](https://github.com/robinebers/openusage/commit/a8c8fa5467f8a6c11b1f5de652388bac9d6904d8) Merge pull request #984 from robinebers/codex/icloud-usage-sync by @robinebers
- [74ef79f](https://github.com/robinebers/openusage/commit/74ef79f211989a61f1ff36ae4f4d5a3cee5cb008) Stop merging disabled provider history by @robinebers
- [c1c131c](https://github.com/robinebers/openusage/commit/c1c131c1d810d03deba3226bac7a46186422ae23) Persist iCloud device identity in Keychain by @robinebers
- [eb71e79](https://github.com/robinebers/openusage/commit/eb71e7948b95f78bd4fc3c6c104bf0b7f4e9236e) Accept team-prefixed iCloud profiles by @robinebers
- [27d3fec](https://github.com/robinebers/openusage/commit/27d3fec3b1084618865c982a577bb853505fc3a9) Bound synced history to refresh window by @robinebers
- [7fb7722](https://github.com/robinebers/openusage/commit/7fb7722f7c8baa5e497ed31360a25734a82e6b1d) Fix Sparkle updater window activation by @robinebers
- [b0c88a0](https://github.com/robinebers/openusage/commit/b0c88a0d2950eea32e1e4d5f7213f684743b0794) Preserve history across scan misses by @robinebers
- [e4b9fba](https://github.com/robinebers/openusage/commit/e4b9fba2eb81811d2e55fe4c5bb11a4d311dd1ae) add `.build-test/` to `.gitignore` by @robinebers
- [23e4e77](https://github.com/robinebers/openusage/commit/23e4e77743ad79e4811eee9ea9915a464f27f1fe) Fix iCloud sync update races by @robinebers
- [ed659c6](https://github.com/robinebers/openusage/commit/ed659c66387d4e0684ec7af4fbe89faf1e910328) Merge pull request #973 from robinebers/claude/github-issue-971-0b9423 by @robinebers
- [b71b371](https://github.com/robinebers/openusage/commit/b71b37128d6a20daac646d2d438c451a07797d00) Polish iCloud sync settings by @robinebers
- [ba515c9](https://github.com/robinebers/openusage/commit/ba515c973303c4fa336ab18392c09771a5a77c7a) Auto-detect iCloud development profiles by @robinebers
- [30cdf85](https://github.com/robinebers/openusage/commit/30cdf85e1fa7f8c30d14d9903882c62fcd96c53d) Fix iCloud provisioning and sync activity state by @robinebers
- [e68b7c1](https://github.com/robinebers/openusage/commit/e68b7c1035b375bfa51ce1fb776792acee6704aa) Refine iCloud sync status by @robinebers
- [9f3f8b6](https://github.com/robinebers/openusage/commit/9f3f8b6034717d219f316c54bb8a2229e2bbf3f5) Add iCloud usage sync by @robinebers
- [6d83bca](https://github.com/robinebers/openusage/commit/6d83bcab416a35f5973027f500c43a5f0529aed9) Merge pull request #982 from robinebers/agent/one-shot-openusage-cli by @robinebers
- [5292c15](https://github.com/robinebers/openusage/commit/5292c152f334898d885422f077ede8aa819e646f) Share provider ordering across limits surfaces by @robinebers
- [2b3e7f7](https://github.com/robinebers/openusage/commit/2b3e7f7e7d92432ea28b5f31d743f7b87343e7be) Expose provider refresh errors in limits by @robinebers
- [fa6ac11](https://github.com/robinebers/openusage/commit/fa6ac11458b04bbf883a8a5acb56cc90ca53b10a) Add machine-readable limits CLI by @robinebers
- [bd9353d](https://github.com/robinebers/openusage/commit/bd9353d1ebb9cb192355faf617a2dca727d1235b) Add one-shot shared-core usage CLI by @robinebers
- [b728d6b](https://github.com/robinebers/openusage/commit/b728d6bca30f0c90423477afeae2282ef563852f) Merge pull request #981 from robinebers/fix/pricing-cursor-grok-4.5-prefix by @robinebers
- [00d2d7e](https://github.com/robinebers/openusage/commit/00d2d7ec26894bd8982e519ef275a2a18154ea0e) fix(pricing): recognize cursor-grok-4.5 usage slugs by @robinebers
- [b75e329](https://github.com/robinebers/openusage/commit/b75e3296a41955a73dce6810bac6a46bf37f2fef) fix: strip the resolved directory prefix when deduping Codex session files by @robinebers
- [4d8bbd6](https://github.com/robinebers/openusage/commit/4d8bbd667d20766424d698f9f100b7ce05f3738b) docs: polish the symlink note in the Claude spend-tiles documentation by @robinebers
- [15b0976](https://github.com/robinebers/openusage/commit/15b0976f26716febcb159ed53cae7c7aab737fc1) Follow symlinked log directories when scanning local usage by @Linyxus

## v0.7.5

### New Features
- Claim Codex rate-limit resets from the popover ([#972](https://github.com/robinebers/openusage/pull/972)) by @robinebers

### Bug Fixes
- Fix Codex window routing by duration ([#980](https://github.com/robinebers/openusage/pull/980)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.4...v0.7.5](https://github.com/robinebers/openusage/compare/v0.7.4...v0.7.5)

- [e1ddf23](https://github.com/robinebers/openusage/commit/e1ddf233faf118aefcadd80dc525064fe44cb689) Fix Codex window routing by duration by @robinebers
- [50e0a94](https://github.com/robinebers/openusage/commit/50e0a949f841ab403a9834ebb14d1f164909a778) fix: say what we know when disabling Use after nothing_to_reset by @robinebers
- [7b6d4a9](https://github.com/robinebers/openusage/commit/7b6d4a9ca33dd34085718b5cf6229675710adf22) fix: retry the post-claim refresh on transient failure; drop the unused popover title by @robinebers
- [ad59baf](https://github.com/robinebers/openusage/commit/ad59baffd786578587598163326d533e92e7e5a6) fix: close the second review's three findings on the claim hardening by @robinebers
- [ce755b9](https://github.com/robinebers/openusage/commit/ce755b954c992465eb88a4cf89a2ded46a0d89d2) fix: harden the resets claim per review findings by @robinebers
- [be00fe2](https://github.com/robinebers/openusage/commit/be00fe2c451b0db4c97c212a527f202753735314) feat: wire the resets claim to the real Codex consume endpoint by @robinebers
- [bb46eae](https://github.com/robinebers/openusage/commit/bb46eae4a9d24cf07d2402e74aa14d0b95c7d44e) feat: animate the resets claim flow by @robinebers
- [20fb41f](https://github.com/robinebers/openusage/commit/20fb41f7c139ab8df5699d82c41117d96b4b5422) feat: claim flow in the Codex resets popover (mocked claim) by @robinebers

## v0.7.4

### New Features
- Cross-provider Total Spend ring card with morphing sectors, provider brand colors, a settings toggle, and capability gating ([#857](https://github.com/robinebers/openusage/pull/857)) by @robinebers
- Add Cost / Tokens / Cost/MTok menu to the Total Spend card ([#906](https://github.com/robinebers/openusage/pull/906)) by @robinebers
- Add OpenCode provider (Zen / Go) from local logs ([#969](https://github.com/robinebers/openusage/pull/969)) by @robinebers
- Add GPT-5.6 pricing aliases ([#880](https://github.com/robinebers/openusage/pull/880)) by @robinebers
- Add Grok 4.5, Kimi K2.7 Code, and Claude 4.7 Opus pricing aliases ([#907](https://github.com/robinebers/openusage/pull/907)) by @robinebers
- Add a hover affordance to Usage Trend values ([#881](https://github.com/robinebers/openusage/pull/881)) by @robinebers
- Replace the Codex resets tooltip with a hover popover and highlight the value on hover ([#879](https://github.com/robinebers/openusage/pull/879)) by @robinebers
- Add hover highlight on spend-row values so the model breakdown reads as interactive ([#877](https://github.com/robinebers/openusage/pull/877)) by @claude

### Bug Fixes
- Improve Options legibility when Increase Transparency is on ([#963](https://github.com/robinebers/openusage/pull/963)) by @validatedev
- Isolate Claude usage cache when the login changes ([#953](https://github.com/robinebers/openusage/pull/953)) by @robinebers
- Prefer profile-scoped Claude login over an inference-only environment token for live usage ([#865](https://github.com/robinebers/openusage/pull/865)) by @joshuavial
- Bind Antigravity credential caches to verified local state and purge on logout ([#961](https://github.com/robinebers/openusage/pull/961)) by @robinebers
- Keep local credential files private ([#910](https://github.com/robinebers/openusage/pull/910)) by @robinebers
- Encode OAuth refresh form values correctly ([#911](https://github.com/robinebers/openusage/pull/911)) by @robinebers
- Validate Cursor usage exports without dropping primary usage ([#948](https://github.com/robinebers/openusage/pull/948)) by @robinebers
- Mark Cursor spend as estimated ([#886](https://github.com/robinebers/openusage/pull/886)) by @robinebers
- Reject malformed Z.ai quota values ([#951](https://github.com/robinebers/openusage/pull/951)) by @robinebers
- Fix request-wide long-context pricing and price GPT-5.6 fast variants correctly ([#885](https://github.com/robinebers/openusage/pull/885), [#889](https://github.com/robinebers/openusage/pull/889)) by @robinebers
- Match Cursor's `grok-4.5-fast-high` pricing slug order ([#908](https://github.com/robinebers/openusage/pull/908)) by @robinebers
- Clear the update banner after the available update is resolved ([#882](https://github.com/robinebers/openusage/pull/882)) by @robinebers
- Keep launch-at-login errors visible ([#887](https://github.com/robinebers/openusage/pull/887)) by @robinebers
- Bound concurrent log parsing and report unreadable usage files without repeated warnings ([#888](https://github.com/robinebers/openusage/pull/888), [#890](https://github.com/robinebers/openusage/pull/890)) by @robinebers
- Preserve the initial popover height and measure it against the correct display ([#904](https://github.com/robinebers/openusage/pull/904)) by @robinebers
- Show Codex usage percentages as reported while keeping near-empty pacing calm ([#905](https://github.com/robinebers/openusage/pull/905)) by @robinebers
- Improve Codex resets popover edge cases (imminent “soon”, zero vs unfetched, two-unit day scale) ([#879](https://github.com/robinebers/openusage/pull/879)) by @robinebers
- Never drop an enablement wake posted mid refresh pass; probe credentials concurrently ([#856](https://github.com/robinebers/openusage/pull/856)) by @robinebers
- Anchor tooltips to the hovered item, balance wrapped lines, and use the cursor’s screen for zero-size anchor fallback ([#858](https://github.com/robinebers/openusage/pull/858)) by @robinebers
- Scope Total Spend to providers with real spend tiles; show the card even when the dashboard is empty ([#857](https://github.com/robinebers/openusage/pull/857)) by @robinebers
- Disable hover tooltips in share-card renders by @robinebers
- Remove the legacy Tauri autostart LaunchAgent on launch ([#876](https://github.com/robinebers/openusage/pull/876)) by @claude
- Single-instance decisions must not trust the LaunchServices snapshot ([#873](https://github.com/robinebers/openusage/pull/873)) by @xuing
- Center the Total Spend share arrow like the provider header icons by @robinebers
- Clear the value highlight when the panel closes by @claude

### Refactor
- Extract layout persistence, startup rules, dashboard sections, and panel management into focused components ([#895](https://github.com/robinebers/openusage/pull/895), [#896](https://github.com/robinebers/openusage/pull/896), [#897](https://github.com/robinebers/openusage/pull/897), [#898](https://github.com/robinebers/openusage/pull/898), [#899](https://github.com/robinebers/openusage/pull/899), [#900](https://github.com/robinebers/openusage/pull/900), [#902](https://github.com/robinebers/openusage/pull/902), [#952](https://github.com/robinebers/openusage/pull/952)) by @robinebers
- Extract `PanelHeightCoordinator`, `StatusItemImageUpdater`, `QuotaNotificationEvaluator`, and `PopoverNavigationStore` ([#869](https://github.com/robinebers/openusage/pull/869), [#870](https://github.com/robinebers/openusage/pull/870), [#871](https://github.com/robinebers/openusage/pull/871), [#872](https://github.com/robinebers/openusage/pull/872)) by @robinebers
- Simplify refresh coalescing, popover visibility, and model-share computation ([#891](https://github.com/robinebers/openusage/pull/891), [#893](https://github.com/robinebers/openusage/pull/893), [#894](https://github.com/robinebers/openusage/pull/894)) by @robinebers
- Remove dead UI and provider code paths ([#883](https://github.com/robinebers/openusage/pull/883), [#950](https://github.com/robinebers/openusage/pull/950)) by @robinebers
- DRY / dead-code / KISS cleanup from code-quality audit ([#868](https://github.com/robinebers/openusage/pull/868)) by @robinebers

### Chores
- Refresh price lists hourly instead of daily ([#909](https://github.com/robinebers/openusage/pull/909)) by @robinebers
- Sync documentation with current app behavior ([#884](https://github.com/robinebers/openusage/pull/884), [#914](https://github.com/robinebers/openusage/pull/914)) by @robinebers
- Test the real metric-divider path ([#892](https://github.com/robinebers/openusage/pull/892)) by @robinebers
- Update README screenshot and version query on screenshot URL by @robinebers
- Fix Pages deploy recovery in release skill to use `main` ref by @robinebers
- Bump PostHog iOS 3.64.1 → 3.64.5 ([#960](https://github.com/robinebers/openusage/pull/960)) by @dependabot[bot]
- Bump actions/deploy-pages 4 → 5 ([#958](https://github.com/robinebers/openusage/pull/958)) by @dependabot[bot]
- Bump actions/upload-pages-artifact 3 → 5 ([#959](https://github.com/robinebers/openusage/pull/959)) by @dependabot[bot]

---

### Changelog
**Full Changelog**: [v0.7.3...v0.7.4](https://github.com/robinebers/openusage/compare/v0.7.3...v0.7.4)

- [766d035](https://github.com/robinebers/openusage/commit/766d03509b68668686aee69e13da3fda8f04ae1c) Address review findings: fail loudly on unreadable OpenCode sources by @robinebers
- [e59c86f](https://github.com/robinebers/openusage/commit/e59c86f3239b0d4b6eb43d0ac73b5c0f2dedd36f) Fix stale-anchor Go plan badge (Bugbot) by @robinebers
- [1bfb96a](https://github.com/robinebers/openusage/commit/1bfb96a7734b24e2cc62bc75e2b63caf9bc7e819) Add OpenCode provider (Zen / Go) from local logs by @robinebers
- [b2aa491](https://github.com/robinebers/openusage/commit/b2aa491292575241ec8615a177041b763a9eaaba) fix(ui): reinforce Options glass in transparent mode by @validatedev
- [8755f62](https://github.com/robinebers/openusage/commit/8755f620cdc04032bb69e289c1acbfd4b486d18c) docs: align credential probe guidance by @robinebers
- [43e20fd](https://github.com/robinebers/openusage/commit/43e20fd01db3013ac0b6931e799d4cbd3c05e80d) docs: correct residual behavior claims by @robinebers
- [113f84a](https://github.com/robinebers/openusage/commit/113f84a1ca7dfd0aa8f9a3ea30a5240102058213) docs: sync current app behavior by @robinebers
- [a378387](https://github.com/robinebers/openusage/commit/a37838773f425672d7b27cc42780b16ef0e9853e) docs: finish layout terminology cleanup by @robinebers
- [710a75e](https://github.com/robinebers/openusage/commit/710a75ecf3e6757f9bdef34f286325605ee98da4) docs: use current layout section names by @robinebers
- [5c47e8b](https://github.com/robinebers/openusage/commit/5c47e8b4b2a6639f0fdd3838540dc49b19c952d8) refactor: split layout store responsibilities by @robinebers
- [1fcdbf2](https://github.com/robinebers/openusage/commit/1fcdbf254b892ce1a924667c6a3345626b53ce2c) refactor: align metric and API-key contracts by @robinebers
- [d7355ad](https://github.com/robinebers/openusage/commit/d7355adaaad0cd6a4cc06dec8d2c3a396dd8c66f) refactor: remove dead text widget parsing by @robinebers
- [61cc416](https://github.com/robinebers/openusage/commit/61cc41602c8baab36def63208ab9e2a0ae2fdf90) docs: describe current refresh and metric paths by @robinebers
- [8042c14](https://github.com/robinebers/openusage/commit/8042c141fd95223a605945d9981ca51e1cc88e9d) test: align coverage with live contracts by @robinebers
- [5ffba86](https://github.com/robinebers/openusage/commit/5ffba868c48809e5e1b01be5e32b4827e6d49a98) refactor: remove dead UI and provider paths by @robinebers
- [d31d37b](https://github.com/robinebers/openusage/commit/d31d37b99cacffa83842902a436336ff8628fcb4) Reuse shared numeric parsing for Z.ai by @robinebers
- [3db9090](https://github.com/robinebers/openusage/commit/3db9090c67dc68728a356596b0b132f75046c219) Keep unknown Z.ai windows forward compatible by @robinebers
- [be28ac6](https://github.com/robinebers/openusage/commit/be28ac6a8919702ccd3a3505261a86184d90a875) Reject malformed Z.ai quota values by @robinebers
- [6dc87ba](https://github.com/robinebers/openusage/commit/6dc87bad90cdd856fa97ce51f588c02775d39499) Reject JSON booleans at numeric boundaries by @robinebers
- [697c7a9](https://github.com/robinebers/openusage/commit/697c7a919826eb029d2b9ecc88032bc74792cb0f) Keep Cursor boundary docs and tests current by @robinebers
- [b1b80e8](https://github.com/robinebers/openusage/commit/b1b80e8639bec9d8ac041a616c33a6e4e7df9eaf) Log Cursor optional endpoint failures by @robinebers
- [fe6ca85](https://github.com/robinebers/openusage/commit/fe6ca85c9d0c20ecaf731034de41b71e3bad961c) Validate Cursor usage exports at the boundary by @robinebers
- [14ab1f5](https://github.com/robinebers/openusage/commit/14ab1f54e7ab68d32986b654fd6e722d226fee8d) fix: reject BOM-prefixed malformed credentials by @robinebers
- [5cd9268](https://github.com/robinebers/openusage/commit/5cd9268bad5f0178abeda7d9580b88b0f2d3be3d) fix: purge Antigravity cache during logout detection by @robinebers
- [4102b00](https://github.com/robinebers/openusage/commit/4102b0062b3a51bbd79aac233215516796046735) Protect credential probes and Antigravity cache by @robinebers
- [33e19b0](https://github.com/robinebers/openusage/commit/33e19b09c688e462a35ef055bd59d6b01b791f87) Bump github.com/posthog/posthog-ios from 3.64.1 to 3.64.5 by @dependabot[bot]
- [3ea0867](https://github.com/robinebers/openusage/commit/3ea0867eb6569dd45d687fcd1ec4218225574114) Bump actions/upload-pages-artifact from 3 to 5 by @dependabot[bot]
- [b66f3ba](https://github.com/robinebers/openusage/commit/b66f3ba8823160478b29c29f39fc2a1b25a0e1da) Bump actions/deploy-pages from 4 to 5 by @dependabot[bot]
- [309f298](https://github.com/robinebers/openusage/commit/309f298edcd5f699e877e272d6d81162cd3d34c3) fix: isolate Claude usage by login by @robinebers
- [906d94f](https://github.com/robinebers/openusage/commit/906d94fc7b0c27f69668dd11d0caa9952408b133) fix: keep credential files private by @robinebers
- [4816fbf](https://github.com/robinebers/openusage/commit/4816fbfb297eb148b055cfd8bf21f20103367d48) fix: correctly encode OAuth form values by @robinebers
- [890d809](https://github.com/robinebers/openusage/commit/890d80937d47eb36a13c537ad88ecc2f199fce2e) chore(pricing): refresh price lists hourly instead of daily by @robinebers
- [e04266c](https://github.com/robinebers/openusage/commit/e04266c75b4ddab0b7fd34964c876ee1cd04bc28) fix(pricing): match Cursor's grok-4.5-fast-high slug order by @robinebers
- [b96b012](https://github.com/robinebers/openusage/commit/b96b012d755af449caf35098191128686b6f5000) feat(pricing): add Grok 4.5, Kimi K2.7 Code, and Claude 4.7 Opus aliases by @robinebers
- [1419a20](https://github.com/robinebers/openusage/commit/1419a20d792aefaee4bb437504335604dc38648f) docs: changelog for v0.7.4-beta.5 by @robinebers
- [a433934](https://github.com/robinebers/openusage/commit/a433934b220c1d6d1bdd02f20fcf7eb5d9791e48) Reorder Total Spend metric menu to Cost, Cost/MTok, Tokens. by @robinebers
- [87e3ef4](https://github.com/robinebers/openusage/commit/87e3ef456cec47bb2e62efd3d3fe079ac3c9e4ba) Add Cost / Tokens / Cost/MTok menu to Total Spend card. by @robinebers
- [e7fa4f9](https://github.com/robinebers/openusage/commit/e7fa4f9d7842bd585362309af2bdcca474ae2347) docs: changelog for v0.7.4-beta.4 by @robinebers
- [a1bdc28](https://github.com/robinebers/openusage/commit/a1bdc288939a9fa8477efed3a2e7bdfbf570d899) Keep near-empty Codex pacing calm by @robinebers
- [5fbc22b](https://github.com/robinebers/openusage/commit/5fbc22b3669b34ebd621765d86b7b8e8ddd211e8) Show Codex usage percentages as reported by @robinebers
- [2da68aa](https://github.com/robinebers/openusage/commit/2da68aa4a5f91cb9b77deee2b2e94ca4dd7daf38) Capture display before measuring panel height by @robinebers
- [4c53fb1](https://github.com/robinebers/openusage/commit/4c53fb1b8fa189900ad28a2cd25d73c21306ed21) Preserve the first panel height on open by @robinebers
- [ac6a3e3](https://github.com/robinebers/openusage/commit/ac6a3e3e12fe2fb1c7e0eceb098f1683ec1bac3c) Extract panel outside-click handling by @robinebers
- [07a35bd](https://github.com/robinebers/openusage/commit/07a35bd7b82ebdd63a3257828f1f8622d1dbde79) Extract panel height handling by @robinebers
- [612d847](https://github.com/robinebers/openusage/commit/612d847893dc3f367ccf7d55bf09b10a5529bcf4) Extract popover footer by @robinebers
- [dba66ad](https://github.com/robinebers/openusage/commit/dba66adac6b07673e0b84f63d108af808cea5399) Extract popover top bar by @robinebers
- [0581cfc](https://github.com/robinebers/openusage/commit/0581cfc5f37c979d2d0d1fbfd3c601a37821cf6c) Extract dashboard scrolling content by @robinebers
- [35842a9](https://github.com/robinebers/openusage/commit/35842a99b18c1364f31cf47780cb752556e1662a) Extract layout startup rules by @robinebers
- [315e6b3](https://github.com/robinebers/openusage/commit/315e6b34749f64650186dee7bfe7a4ca921df3ee) Extract layout persistence by @robinebers
- [a8750e7](https://github.com/robinebers/openusage/commit/a8750e70b785cf00ee118cb813b2b168f5c62d34) Keep unreadable log warnings quiet across batches by @robinebers
- [76247d7](https://github.com/robinebers/openusage/commit/76247d7c7de32b38e1ee28d02144aef3453b8bee) Test the real metric divider path by @robinebers
- [8ddc401](https://github.com/robinebers/openusage/commit/8ddc401ee97c6b740c5a65e17dec33630533cba6) Compute model shares once per render by @robinebers
- [f44d4ef](https://github.com/robinebers/openusage/commit/f44d4ef783e2a7e380b131bc8a7a84fa2c51fbab) Use the controller popover visibility signal by @robinebers
- [1040f53](https://github.com/robinebers/openusage/commit/1040f5356a29e1a0beb372ac36d205f28c0685b2) fix(claude): prefer profile-scoped login over inference-only env token for live usage by @joshuavial
- [2d4a5b4](https://github.com/robinebers/openusage/commit/2d4a5b42ac8bb7c786901faee8002d22934d4ec4) Simplify menu bar refresh coalescing by @robinebers
- [c0b190f](https://github.com/robinebers/openusage/commit/c0b190f13d3fa38eca8c1bc7a880ed4a35f47c9c) Log unreadable usage files once by @robinebers
- [f8e02b5](https://github.com/robinebers/openusage/commit/f8e02b59228aaa49250b8bf4b49dfad9740ce64b) fix(pricing): price GPT-5.6 fast variants by @robinebers
- [27ebb0b](https://github.com/robinebers/openusage/commit/27ebb0b9792579cd05ee13f4f6d743b9576a6ebc) Bound concurrent log parsing by @robinebers
- [27bd492](https://github.com/robinebers/openusage/commit/27bd492ee1e907c0143d76bea8d8c030417f8516) Keep launch-at-login errors visible by @robinebers
- [2669a7b](https://github.com/robinebers/openusage/commit/2669a7bbc6b1298c84d94e43b19fff93d4e1f40a) Mark Cursor spend as estimated by @robinebers
- [e881be6](https://github.com/robinebers/openusage/commit/e881be608c07c9f544b5e6eab5e10e0eeaa55334) Fix request-wide long-context pricing by @robinebers
- [1bcc8f9](https://github.com/robinebers/openusage/commit/1bcc8f9756dc07e4937b93f2bc92e1d6330eeee6) Refresh pricing and panel documentation by @robinebers
- [4b61302](https://github.com/robinebers/openusage/commit/4b61302f1ff84d9747c9c398f1a59b8bfecff5f2) Remove unused UI plumbing by @robinebers
- [3194f3b](https://github.com/robinebers/openusage/commit/3194f3baf7c436309a0f1d5f86487bee85e6f764) Clear resolved update banner by @robinebers
- [c9be949](https://github.com/robinebers/openusage/commit/c9be949905038a4214fe011f5286ab79ee86112c) Add hover affordance to usage trend by @robinebers
- [8a8ea33](https://github.com/robinebers/openusage/commit/8a8ea33c3e690da980b2832fa1c151330784608d) Add GPT-5.6 pricing aliases and tests by @robinebers
- [6c99db7](https://github.com/robinebers/openusage/commit/6c99db7b33b4bada373507c105e14d68a2b72188) docs: changelog for v0.7.4-beta.3 by @robinebers
- [0506f02](https://github.com/robinebers/openusage/commit/0506f02d00abee909ba50028cbe8679df67eff75) Always show two units at the day scale in compactDuration by @robinebers
- [417900f](https://github.com/robinebers/openusage/commit/417900f1cf27586895a6de13a775c3511f8678ce) Collapse imminent resets to "soon" and gate the popover on real data by @robinebers
- [5f42ee9](https://github.com/robinebers/openusage/commit/5f42ee9c2eb59a980ccfaeb3de4a89b02a1682d9) Distinguish zero resets from unfetched expiries in the popover by @robinebers
- [cbe303e](https://github.com/robinebers/openusage/commit/cbe303ec5ddf3437b20506de25da6ace39cc20cd) Replace Codex resets tooltip with a hover popover and light its value by @robinebers
- [dd53cbe](https://github.com/robinebers/openusage/commit/dd53cbed89358d4c3ad1e8bee23ebae3368121c4) Clear the value highlight on panel close by tracking hover on the coordinator by @claude
- [71a6ba0](https://github.com/robinebers/openusage/commit/71a6ba00c0f3a025c0028b51748b1cf2dc0a7ab6) Add hover highlight to spend-row value so the model breakdown reads as interactive by @claude
- [9cf0c62](https://github.com/robinebers/openusage/commit/9cf0c62de4396c3bab2ce23ccb35062b796afd08) Address review findings: real clamp coverage, private clamped, honest imports by @claude
- [84879dd](https://github.com/robinebers/openusage/commit/84879dd4704e2974b2cbf4e1aa44f1f6e77afe5a) Address review findings: non-optional image updater, fix stale doc reference by @claude
- [43241b4](https://github.com/robinebers/openusage/commit/43241b411486bf29285429764febd27e63edade1) Address review findings: fix stale dedup doc, note the snapshot delta by @claude
- [7f1af89](https://github.com/robinebers/openusage/commit/7f1af892eab1f001ea72e82dec9825cc558e8b89) Address review findings: private navigation, naming, stale doc, notice tests by @claude
- [7cc1f25](https://github.com/robinebers/openusage/commit/7cc1f25e9496dd274ba6e19d08d1c8a001030ef9) Address review findings: pill shadow drift, test pins, Cursor facts adoption by @claude
- [dff6786](https://github.com/robinebers/openusage/commit/dff6786e907b0f9d0d07101b339cb1899c6a728e) fix: remove the legacy Tauri autostart LaunchAgent on launch by @claude
- [ea51bdf](https://github.com/robinebers/openusage/commit/ea51bdf7b038fbe81039a43cf109edaf8faa6565) fix: single-instance decisions must not trust the LaunchServices snapshot (#874) by @xuing
- [f0baad2](https://github.com/robinebers/openusage/commit/f0baad20a936252b2c21a075db7b75c4f224783e) refactor(DashboardView): extract PanelHeightCoordinator (auto-fit computation) by @robinebers
- [c4c5971](https://github.com/robinebers/openusage/commit/c4c59712692ed0296fd25f810a3d741995abf70d) refactor(StatusItemController): extract StatusItemImageUpdater by @robinebers
- [89ee82e](https://github.com/robinebers/openusage/commit/89ee82ecfa9e7defa6ded0e7ce3d6f0e748acb29) refactor(WidgetDataStore): extract QuotaNotificationEvaluator by @robinebers
- [7597156](https://github.com/robinebers/openusage/commit/75971560e962636822fd7cdcd8ae553ab8670d24) refactor(LayoutStore): extract PopoverNavigationStore + generic TransientNotice by @robinebers
- [667f350](https://github.com/robinebers/openusage/commit/667f350a1499514451e5eb131fd5cbecdda4d8b8) refactor: DRY/dead-code/KISS cleanup from code-quality audit by @robinebers
- [4d75562](https://github.com/robinebers/openusage/commit/4d7556269013cf5c9c76216caf2e6fd008dff742) Add version query to screenshot URL in README by @robinebers
- [a26a113](https://github.com/robinebers/openusage/commit/a26a113081799fd010cc00f5aeaa79a0bf8eb014) docs: update README screenshot by @robinebers
- [ba04c54](https://github.com/robinebers/openusage/commit/ba04c54f68215a42a370e0a302f71a416421d0f1) docs(skills): fix Pages deploy recovery to use main ref by @robinebers
- [3686abc](https://github.com/robinebers/openusage/commit/3686abc136db12f236ab66898c7026d51cd655f3) fix(ui): center the Total Spend share arrow like the provider header icons by @robinebers
- [bfd6e68](https://github.com/robinebers/openusage/commit/bfd6e6846bd4a1a83bcf27c2e76ee804c6504fb3) docs: changelog for v0.7.4-beta.2 by @robinebers
- [141bf53](https://github.com/robinebers/openusage/commit/141bf5311fd3c528e61606c6fe9641f8173f7957) fix(share): disable hover tooltips in share-card renders by @robinebers
- [e740324](https://github.com/robinebers/openusage/commit/e7403241a53577dfa1b5fc7ad26f0788639cfd8e) docs: changelog for v0.7.4-beta.1 by @robinebers
- [1d24835](https://github.com/robinebers/openusage/commit/1d2483503fc5c445eb93c959a61e88d5235567fb) fix: derive Total Spend info tooltip from enabled spend-capable providers by @robinebers
- [a00f786](https://github.com/robinebers/openusage/commit/a00f786c8b8417e998755ea535a85a64b325523d) fix(tooltip): pick the cursor's screen for the zero-size anchor fallback by @robinebers
- [c95f7c8](https://github.com/robinebers/openusage/commit/c95f7c895741af280793de7d5af1e9250cb73c6d) fix(dashboard): scope Total Spend to real spend-tile providers, show card with empty dashboard by @robinebers
- [97dec12](https://github.com/robinebers/openusage/commit/97dec12a2ea4c61bf5b5642cef52468705353775) fix(tooltip): anchor bubble to the hovered item and balance wrapped lines by @robinebers
- [c56d8d1](https://github.com/robinebers/openusage/commit/c56d8d17e821d0dad6fc7fbf3c188dd6333766cb) feat(dashboard): morphing ring sectors, brand colors, settings toggle, capability gating by @robinebers
- [53115a8](https://github.com/robinebers/openusage/commit/53115a8275b9e95935277863a8da2693eb99f1a7) Revert "feat(dashboard): stacked-bars variant of the Total Spend card" by @robinebers
- [684ccdc](https://github.com/robinebers/openusage/commit/684ccdc9a087c9a55dc3dccfd00247b5106f0bd6) feat(dashboard): stacked-bars variant of the Total Spend card by @robinebers
- [8251ac3](https://github.com/robinebers/openusage/commit/8251ac3d3e7c9296ba245a94ee5e6560139e8d29) feat(dashboard): cross-provider Total Spend ring card by @robinebers
- [2a225eb](https://github.com/robinebers/openusage/commit/2a225ebba05f599fc5b8cdc2708b76ff78868856) fix(refresh): never lose an enablement wake posted mid-pass; probe credentials concurrently by @robinebers

## v0.7.4-beta.5

### New Features
- Add Cost / Tokens / Cost/MTok menu to Total Spend card. ([#906](https://github.com/robinebers/openusage/pull/906)) by @robinebers

### Bug Fixes
- Reorder Total Spend metric menu to Cost, Cost/MTok, Tokens. ([#906](https://github.com/robinebers/openusage/pull/906)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.4-beta.4...v0.7.4-beta.5](https://github.com/robinebers/openusage/compare/v0.7.4-beta.4...v0.7.4-beta.5)

- [a433934](https://github.com/robinebers/openusage/commit/a433934b220c1d6d1bdd02f20fcf7eb5d9791e48) Reorder Total Spend metric menu to Cost, Cost/MTok, Tokens. by @robinebers
- [87e3ef4](https://github.com/robinebers/openusage/commit/87e3ef456cec47bb2e62efd3d3fe079ac3c9e4ba) Add Cost / Tokens / Cost/MTok menu to Total Spend card. by @robinebers

## v0.7.4-beta.4

### New Features
- Add GPT-5.6 pricing aliases and tests ([#880](https://github.com/robinebers/openusage/pull/880)) by @robinebers
- Add a hover affordance to Usage Trend values ([#881](https://github.com/robinebers/openusage/pull/881)) by @robinebers

### Bug Fixes
- Clear the update banner after the available update is resolved ([#882](https://github.com/robinebers/openusage/pull/882)) by @robinebers
- Fix request-wide long-context pricing and price GPT-5.6 fast variants correctly ([#885](https://github.com/robinebers/openusage/pull/885), [#889](https://github.com/robinebers/openusage/pull/889)) by @robinebers
- Mark Cursor spend as estimated ([#886](https://github.com/robinebers/openusage/pull/886)) by @robinebers
- Keep launch-at-login errors visible ([#887](https://github.com/robinebers/openusage/pull/887)) by @robinebers
- Bound concurrent log parsing and report unreadable usage files without repeated warnings ([#888](https://github.com/robinebers/openusage/pull/888), [#890](https://github.com/robinebers/openusage/pull/890)) by @robinebers
- Prefer profile-scoped Claude login over an inference-only environment token for live usage ([#865](https://github.com/robinebers/openusage/pull/865)) by @joshuavial
- Preserve the initial popover height and measure it against the correct display ([#904](https://github.com/robinebers/openusage/pull/904)) by @robinebers
- Show Codex usage percentages as reported while keeping near-empty pacing calm ([#905](https://github.com/robinebers/openusage/pull/905)) by @robinebers

### Refactor
- Remove unused UI plumbing ([#883](https://github.com/robinebers/openusage/pull/883)) by @robinebers
- Simplify refresh coalescing, popover visibility, and model-share computation ([#891](https://github.com/robinebers/openusage/pull/891), [#893](https://github.com/robinebers/openusage/pull/893), [#894](https://github.com/robinebers/openusage/pull/894)) by @robinebers
- Extract layout persistence, startup rules, dashboard sections, and panel management into focused components ([#895](https://github.com/robinebers/openusage/pull/895), [#896](https://github.com/robinebers/openusage/pull/896), [#897](https://github.com/robinebers/openusage/pull/897), [#898](https://github.com/robinebers/openusage/pull/898), [#899](https://github.com/robinebers/openusage/pull/899), [#900](https://github.com/robinebers/openusage/pull/900), [#902](https://github.com/robinebers/openusage/pull/902)) by @robinebers

### Chores
- Refresh pricing and panel documentation ([#884](https://github.com/robinebers/openusage/pull/884)) by @robinebers
- Test the real metric-divider path ([#892](https://github.com/robinebers/openusage/pull/892)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.4-beta.3...v0.7.4-beta.4](https://github.com/robinebers/openusage/compare/v0.7.4-beta.3...v0.7.4-beta.4)

- [a1bdc28](https://github.com/robinebers/openusage/commit/a1bdc288939a9fa8477efed3a2e7bdfbf570d899) Keep near-empty Codex pacing calm by @robinebers
- [5fbc22b](https://github.com/robinebers/openusage/commit/5fbc22b3669b34ebd621765d86b7b8e8ddd211e8) Show Codex usage percentages as reported by @robinebers
- [2da68aa](https://github.com/robinebers/openusage/commit/2da68aa4a5f91cb9b77deee2b2e94ca4dd7daf38) Capture display before measuring panel height by @robinebers
- [4c53fb1](https://github.com/robinebers/openusage/commit/4c53fb1b8fa189900ad28a2cd25d73c21306ed21) Preserve the first panel height on open by @robinebers
- [ac6a3e3](https://github.com/robinebers/openusage/commit/ac6a3e3e12fe2fb1c7e0eceb098f1683ec1bac3c) Extract panel outside-click handling by @robinebers
- [07a35bd](https://github.com/robinebers/openusage/commit/07a35bd7b82ebdd63a3257828f1f8622d1dbde79) Extract panel height handling by @robinebers
- [612d847](https://github.com/robinebers/openusage/commit/612d847893dc3f367ccf7d55bf09b10a5529bcf4) Extract popover footer by @robinebers
- [dba66ad](https://github.com/robinebers/openusage/commit/dba66adac6b07673e0b84f63d108af808cea5399) Extract popover top bar by @robinebers
- [0581cfc](https://github.com/robinebers/openusage/commit/0581cfc5f37c979d2d0d1fbfd3c601a37821cf6c) Extract dashboard scrolling content by @robinebers
- [35842a9](https://github.com/robinebers/openusage/commit/35842a99b18c1364f31cf47780cb752556e1662a) Extract layout startup rules by @robinebers
- [315e6b3](https://github.com/robinebers/openusage/commit/315e6b34749f64650186dee7bfe7a4ca921df3ee) Extract layout persistence by @robinebers
- [a8750e7](https://github.com/robinebers/openusage/commit/a8750e70b785cf00ee118cb813b2b168f5c62d34) Keep unreadable log warnings quiet across batches by @robinebers
- [76247d7](https://github.com/robinebers/openusage/commit/76247d7c7de32b38e1ee28d02144aef3453b8bee) Test the real metric divider path by @robinebers
- [8ddc401](https://github.com/robinebers/openusage/commit/8ddc401ee97c6b740c5a65e17dec33630533cba6) Compute model shares once per render by @robinebers
- [f44d4ef](https://github.com/robinebers/openusage/commit/f44d4ef783e2a7e380b131bc8a7a84fa2c51fbab) Use the controller popover visibility signal by @robinebers
- [1040f53](https://github.com/robinebers/openusage/commit/1040f5356a29e1a0beb372ac36d205f28c0685b2) fix(claude): prefer profile-scoped login over inference-only env token for live usage by @joshuavial
- [2d4a5b4](https://github.com/robinebers/openusage/commit/2d4a5b42ac8bb7c786901faee8002d22934d4ec4) Simplify menu bar refresh coalescing by @robinebers
- [c0b190f](https://github.com/robinebers/openusage/commit/c0b190f13d3fa38eca8c1bc7a880ed4a35f47c9c) Log unreadable usage files once by @robinebers
- [f8e02b5](https://github.com/robinebers/openusage/commit/f8e02b59228aaa49250b8bf4b49dfad9740ce64b) fix(pricing): price GPT-5.6 fast variants by @robinebers
- [27ebb0b](https://github.com/robinebers/openusage/commit/27ebb0b9792579cd05ee13f4f6d743b9576a6ebc) Bound concurrent log parsing by @robinebers
- [27bd492](https://github.com/robinebers/openusage/commit/27bd492ee1e907c0143d76bea8d8c030417f8516) Keep launch-at-login errors visible by @robinebers
- [2669a7b](https://github.com/robinebers/openusage/commit/2669a7bbc6b1298c84d94e43b19fff93d4e1f40a) Mark Cursor spend as estimated by @robinebers
- [e881be6](https://github.com/robinebers/openusage/commit/e881be608c07c9f544b5e6eab5e10e0eeaa55334) Fix request-wide long-context pricing by @robinebers
- [1bcc8f9](https://github.com/robinebers/openusage/commit/1bcc8f9756dc07e4937b93f2bc92e1d6330eeee6) Refresh pricing and panel documentation by @robinebers
- [4b61302](https://github.com/robinebers/openusage/commit/4b61302f1ff84d9747c9c398f1a59b8bfecff5f2) Remove unused UI plumbing by @robinebers
- [3194f3b](https://github.com/robinebers/openusage/commit/3194f3baf7c436309a0f1d5f86487bee85e6f764) Clear resolved update banner by @robinebers
- [c9be949](https://github.com/robinebers/openusage/commit/c9be949905038a4214fe011f5286ab79ee86112c) Add hover affordance to usage trend by @robinebers
- [8a8ea33](https://github.com/robinebers/openusage/commit/8a8ea33c3e690da980b2832fa1c151330784608d) Add GPT-5.6 pricing aliases and tests by @robinebers

## v0.7.4-beta.3

### New Features
- Replace Codex resets tooltip with a hover popover and highlight the value on hover by @robinebers
- Add hover highlight on spend-row values so the model breakdown reads as interactive by @claude

### Bug Fixes
- Always show two units at the day scale in `compactDuration` by @robinebers
- Collapse imminent resets to “soon” and gate the popover on real data by @robinebers
- Distinguish zero resets from unfetched expiries in the Codex resets popover by @robinebers
- Clear the value highlight when the panel closes by tracking hover on the coordinator by @claude
- Remove the legacy Tauri autostart LaunchAgent on launch by @claude
- Single-instance decisions must not trust the LaunchServices snapshot ([#874](https://github.com/robinebers/openusage/pull/874)) by @xuing
- Center the Total Spend share arrow like the provider header icons by @robinebers

### Refactor
- Extract `PanelHeightCoordinator` from `DashboardView` (auto-fit computation) by @robinebers
- Extract `StatusItemImageUpdater` from `StatusItemController` by @robinebers
- Extract `QuotaNotificationEvaluator` from `WidgetDataStore` by @robinebers
- Extract `PopoverNavigationStore` and generic `TransientNotice` from `LayoutStore` by @robinebers
- DRY / dead-code / KISS cleanup from code-quality audit by @robinebers

### Chores
- Address review findings (clamp coverage, image updater, navigation, dedup docs, pill shadow, tests) by @claude
- Update README screenshot and version query on screenshot URL by @robinebers
- Fix Pages deploy recovery in release skill to use `main` ref by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.4-beta.2...v0.7.4-beta.3](https://github.com/robinebers/openusage/compare/v0.7.4-beta.2...v0.7.4-beta.3)

- [0506f02](https://github.com/robinebers/openusage/commit/0506f02d00abee909ba50028cbe8679df67eff75) Always show two units at the day scale in compactDuration by @robinebers
- [417900f1](https://github.com/robinebers/openusage/commit/417900f1cf27586895a6de13a775c3511f8678ce) Collapse imminent resets to "soon" and gate the popover on real data by @robinebers
- [5f42ee9c](https://github.com/robinebers/openusage/commit/5f42ee9c2eb59a980ccfaeb3de4a89b02a1682d9) Distinguish zero resets from unfetched expiries in the popover by @robinebers
- [cbe303ec](https://github.com/robinebers/openusage/commit/cbe303ec5ddf3437b20506de25da6ace39cc20cd) Replace Codex resets tooltip with a hover popover and light its value by @robinebers
- [dd53cbed](https://github.com/robinebers/openusage/commit/dd53cbed89358d4c3ad1e8bee23ebae3368121c4) Clear the value highlight on panel close by tracking hover on the coordinator by @claude
- [71a6ba00](https://github.com/robinebers/openusage/commit/71a6ba00c0f3a025c0028b51748b1cf2dc0a7ab6) Add hover highlight to spend-row value so the model breakdown reads as interactive by @claude
- [9cf0c62d](https://github.com/robinebers/openusage/commit/9cf0c62de4396c3bab2ce23ccb35062b796afd08) Address review findings: real clamp coverage, private clamped, honest imports by @claude
- [84879dd4](https://github.com/robinebers/openusage/commit/84879dd4704e2974b2cbf4e1aa44f1f6e77afe5a) Address review findings: non-optional image updater, fix stale doc reference by @claude
- [43241b41](https://github.com/robinebers/openusage/commit/43241b411486bf29285429764febd27e63edade1) Address review findings: fix stale dedup doc, note the snapshot delta by @claude
- [7f1af892](https://github.com/robinebers/openusage/commit/7f1af892eab1f001ea72e82dec9825cc558e8b89) Address review findings: private navigation, naming, stale doc, notice tests by @claude
- [7cc1f25e](https://github.com/robinebers/openusage/commit/7cc1f25e9496dd274ba6e19d08d1c8a001030ef9) Address review findings: pill shadow drift, test pins, Cursor facts adoption by @claude
- [dff6786e](https://github.com/robinebers/openusage/commit/dff6786e907b0f9d0d07101b339cb1899c6a728e) fix: remove the legacy Tauri autostart LaunchAgent on launch by @claude
- [ea51bdf7](https://github.com/robinebers/openusage/commit/ea51bdf7b038fbe81039a43cf109edaf8faa6565) fix: single-instance decisions must not trust the LaunchServices snapshot (#874) by @xuing
- [f0baad20](https://github.com/robinebers/openusage/commit/f0baad20a936252b2c21a075db7b75c4f224783e) refactor(DashboardView): extract PanelHeightCoordinator (auto-fit computation) by @robinebers
- [c4c59712](https://github.com/robinebers/openusage/commit/c4c59712692ed0296fd25f810a3d741995abf70d) refactor(StatusItemController): extract StatusItemImageUpdater by @robinebers
- [89ee82ec](https://github.com/robinebers/openusage/commit/89ee82ecfa9e7defa6ded0e7ce3d6f0e748acb29) refactor(WidgetDataStore): extract QuotaNotificationEvaluator by @robinebers
- [75971560](https://github.com/robinebers/openusage/commit/75971560e962636822fd7cdcd8ae553ab8670d24) refactor(LayoutStore): extract PopoverNavigationStore + generic TransientNotice by @robinebers
- [667f350a](https://github.com/robinebers/openusage/commit/667f350a1499514451e5eb131fd5cbecdda4d8b8) refactor: DRY/dead-code/KISS cleanup from code-quality audit by @robinebers
- [4d755626](https://github.com/robinebers/openusage/commit/4d7556269013cf5c9c76216caf2e6fd008dff742) Add version query to screenshot URL in README by @robinebers
- [a26a1130](https://github.com/robinebers/openusage/commit/a26a113081799fd010cc00f5aeaa79a0bf8eb014) docs: update README screenshot by @robinebers
- [ba04c54f](https://github.com/robinebers/openusage/commit/ba04c54f68215a42a370e0a302f71a416421d0f1) docs(skills): fix Pages deploy recovery to use main ref by @robinebers
- [3686abc1](https://github.com/robinebers/openusage/commit/3686abc136db12f236ab66898c7026d51cd655f3) fix(ui): center the Total Spend share arrow like the provider header icons by @robinebers

## v0.7.4-beta.2

### Bug Fixes
- Disable hover tooltips in share-card renders by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.4-beta.1...v0.7.4-beta.2](https://github.com/robinebers/openusage/compare/v0.7.4-beta.1...v0.7.4-beta.2)

- [141bf53](https://github.com/robinebers/openusage/commit/141bf5311fd3c528e61606c6fe9641f8173f7957) fix(share): disable hover tooltips in share-card renders by @robinebers

## v0.7.4-beta.1

### New Features
- Cross-provider Total Spend ring card with morphing sectors, provider brand colors, a settings toggle, and capability gating ([#13120](https://github.com/robinebers/openusage/pull/13120)) by @robinebers

### Bug Fixes
- Never drop an enablement wake posted mid refresh pass; probe credentials concurrently by @robinebers
- Anchor tooltips to the hovered item, balance wrapped lines, and use the cursor’s screen for zero-size anchor fallback by @robinebers
- Scope Total Spend to providers with real spend tiles; show the card even when the dashboard is empty by @robinebers
- Derive the Total Spend info tooltip from enabled spend-capable providers by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.3...v0.7.4-beta.1](https://github.com/robinebers/openusage/compare/v0.7.3...v0.7.4-beta.1)

- [1d24835](https://github.com/robinebers/openusage/commit/1d2483503fc5c445eb93c959a61e88d5235567fb) fix: derive Total Spend info tooltip from enabled spend-capable providers by @robinebers
- [a00f786](https://github.com/robinebers/openusage/commit/a00f786c8b8417e998755ea535a85a64b325523d) fix(tooltip): pick the cursor's screen for the zero-size anchor fallback by @robinebers
- [c95f7c8](https://github.com/robinebers/openusage/commit/c95f7c895741af280793de7d5af1e9250cb73c6d) fix(dashboard): scope Total Spend to real spend-tile providers, show card with empty dashboard by @robinebers
- [97dec12](https://github.com/robinebers/openusage/commit/97dec12a2ea4c61bf5b5642cef52468705353775) fix(tooltip): anchor bubble to the hovered item and balance wrapped lines by @robinebers
- [c56d8d1](https://github.com/robinebers/openusage/commit/c56d8d17e821d0dad6fc7fbf3c188dd6333766cb) feat(dashboard): morphing ring sectors, brand colors, settings toggle, capability gating by @robinebers
- [53115a8](https://github.com/robinebers/openusage/commit/53115a8275b9e95935277863a8da2693eb99f1a7) Revert "feat(dashboard): stacked-bars variant of the Total Spend card" by @robinebers
- [684ccdc](https://github.com/robinebers/openusage/commit/684ccdc9a087c9a55dc3dccfd00247b5106f0bd6) feat(dashboard): stacked-bars variant of the Total Spend card by @robinebers
- [8251ac3](https://github.com/robinebers/openusage/commit/8251ac3d3e7c9296ba245a94ee5e6560139e8d29) feat(dashboard): cross-provider Total Spend ring card by @robinebers
- [2a225eb](https://github.com/robinebers/openusage/commit/2a225ebba05f599fc5b8cdc2708b76ff78868856) fix(refresh): never lose an enablement wake posted mid-pass; probe credentials concurrently by @robinebers

## v0.7.3

### New Features
- Native log scanners and dynamic model pricing; drop ccusage ([#827](https://github.com/robinebers/openusage/pull/827)) by @robinebers
- Fresh installs start with detected providers and a welcome card ([#830](https://github.com/robinebers/openusage/pull/830)) by @robinebers
- Credential-detect providers added by updates; unify installs on enabled-list mode ([#838](https://github.com/robinebers/openusage/pull/838)) by @robinebers
- Copilot org-level AI credit usage for org-managed Business/Enterprise seats ([#843](https://github.com/robinebers/openusage/pull/843)) by @robinebers
- In-popover update banner and Sparkle 2.9.4 focus fix ([#842](https://github.com/robinebers/openusage/pull/842)) by @robinebers
- Replace footer split button with a single Options menu ([#841](https://github.com/robinebers/openusage/pull/841)) by @robinebers
- Include Cowork session logs in Claude local spend tiles ([#845](https://github.com/robinebers/openusage/pull/845)) by @robinebers
- Per-model spend breakdown when hovering Today / Yesterday / Last 30 Days rows ([#850](https://github.com/robinebers/openusage/pull/850)) by @robinebers
- Reset All re-detects installed tools ([#853](https://github.com/robinebers/openusage/pull/853)) by @robinebers
- Codex status dot for reset-credit expiry ([#854](https://github.com/robinebers/openusage/pull/854)) by @robinebers
- Grok weekly shared-pool meter from the credits config by @validatedev

### Bug Fixes
- Opus 4.7/4.8 fast-mode rates match Cursor's published pricing ([#835](https://github.com/robinebers/openusage/pull/835)) by @robinebers
- Claude: explain CLI login when only the desktop app is signed in ([#828](https://github.com/robinebers/openusage/pull/828)) by @robinebers
- Copilot: keep probing other orgs when one org's billing has an outage ([#843](https://github.com/robinebers/openusage/pull/843)) by @robinebers
- Copilot: don't let a placeholder Extra Usage row block the org billing lookup ([#844](https://github.com/robinebers/openusage/pull/844)) by @robinebers
- Open the popover when a pace notification is tapped ([#840](https://github.com/robinebers/openusage/pull/840)) by @robinebers
- Claude: surface rate-limited state as a header warning instead of a silent blank ([#849](https://github.com/robinebers/openusage/pull/849)) by @robinebers
- Exclude unpriceable usage from every displayed spend total ([#853](https://github.com/robinebers/openusage/pull/853)) by @robinebers
- Model breakdown opens only from the value column; breakdown percentages always sum to 100 ([#850](https://github.com/robinebers/openusage/pull/850)) by @robinebers
- Grok: reject protobuf varints whose 10th byte overflows 64 bits by @validatedev

### Refactor
- Grok: read weekly pool from the CLI JSON credits endpoint and drop the legacy monthly meter by @robinebers
- Copilot: default both org billing metrics below the expand caret ([#843](https://github.com/robinebers/openusage/pull/843)) by @robinebers

### Chores
- Bump PostHog iOS and actions/checkout ([#848](https://github.com/robinebers/openusage/pull/848), [#847](https://github.com/robinebers/openusage/pull/847)) by @app/dependabot
- Trigger Pages deploy from Release and pricing-supplement workflow completion by @robinebers
- Split GrokProviderTests into per-class files by @validatedev

---

### Changelog
**Full Changelog**: [v0.7.2...v0.7.3](https://github.com/robinebers/openusage/compare/v0.7.2...v0.7.3)

- [68cc5c6](https://github.com/robinebers/openusage/commit/68cc5c6f712bda45490a16469119fcaab5256896) feat(spend): native log scanners + dynamic model pricing, drop ccusage by @robinebers
- [be66c05](https://github.com/robinebers/openusage/commit/be66c0510eb3b4e7f66c5ab06a1ba0863988a7a7) fix(claude): explain CLI login when only the desktop app is signed in by @robinebers
- [5ea794a](https://github.com/robinebers/openusage/commit/5ea794a75d7a975c9f2cb7a3ef54dde0607ee13f) fix(claude): only show desktop-app hint when no CLI credentials are stored by @robinebers
- [7aeead1](https://github.com/robinebers/openusage/commit/7aeead1ca9e0615289b3e43bef3c5a594aa539b3) docs: add pricing-update skill for syncing the pricing supplement by @robinebers
- [59008dd](https://github.com/robinebers/openusage/commit/59008dddc2758f76df1d1a8c5ed4f4f170b49bcb) feat(onboarding): fresh installs start with detected providers + welcome card by @robinebers
- [e26b1c8](https://github.com/robinebers/openusage/commit/e26b1c83554933d86d585c9a4d2676a5a4cfcfa1) fix(tests): repair desktop-app-hint test broken by ccusage removal on main by @robinebers
- [4fe8d17](https://github.com/robinebers/openusage/commit/4fe8d17a43a0dd8880a2311f6e8b4b5e73a1543c) fix(tests): port #828's desktop-app test off the removed CcusageRunner by @robinebers
- [3c5882a](https://github.com/robinebers/openusage/commit/3c5882abb9a23cc85e7776395f0fd0130061c7ec) fix(pricing): override Opus 4.7/4.8 fast-mode rates with Cursor's published pricing by @robinebers
- [8904e73](https://github.com/robinebers/openusage/commit/8904e73206e8a6d2af8a8f2f95205de99beb06bb) docs: changelog for v0.7.3-beta.1 by @robinebers
- [1b077d1](https://github.com/robinebers/openusage/commit/1b077d18b30f2cbbda2787735bb23020218e891e) feat(providers): credential-detect providers added by updates; unify installs on enabled-list mode by @robinebers
- [224c987](https://github.com/robinebers/openusage/commit/224c987c442a3d87ff14b4366835f7c683727dd4) Open the popover when a pace notification is tapped. by @robinebers
- [db821dd](https://github.com/robinebers/openusage/commit/db821dd2191e94a9a9443adf8af5bc41b21d0948) feat(ui): replace footer split button with a single Options menu by @robinebers
- [7cf5645](https://github.com/robinebers/openusage/commit/7cf564507738c4e4af06d6243e11a5c733dffc0c) feat(updates): in-popover update banner + Sparkle 2.9.4 focus fix by @robinebers
- [8b567ae](https://github.com/robinebers/openusage/commit/8b567aeeb8f53d094dba8af79711e3eaff7679dc) feat(copilot): show org-level AI credit usage for org-managed Business/Enterprise seats by @robinebers
- [1171895](https://github.com/robinebers/openusage/commit/1171895a30ea2a5764ad6a9c65dbd8cd305b17b2) refactor(copilot): default both org billing metrics below the expand caret by @robinebers
- [b15a47e](https://github.com/robinebers/openusage/commit/b15a47ed6df02a5ce6eb0672ed5ffc5aac65e702) fix(copilot): keep probing other orgs when one org's billing has an outage by @robinebers
- [2d275d5](https://github.com/robinebers/openusage/commit/2d275d564c6abea4b16071184ecc60b9ba04c878) docs: changelog for v0.7.3-beta.2 by @robinebers
- [9709169](https://github.com/robinebers/openusage/commit/9709169108004785d34b7d5ecc1cccfd6fd2d8e2) fix(copilot): don't let a placeholder Extra Usage row block the org billing lookup by @robinebers
- [e30769d](https://github.com/robinebers/openusage/commit/e30769d31d18ba967e4cd1dc57e7aebf0039ff69) docs: changelog for v0.7.3-beta.3 by @robinebers
- [9fa1923](https://github.com/robinebers/openusage/commit/9fa1923113de6205af83c7dd412ad07ccd77dc9b) chore(deps): bump actions/checkout from 4 to 7 (#847) by @app/dependabot
- [0b8c39f](https://github.com/robinebers/openusage/commit/0b8c39f1ffeb61015f5deb6b91121d9083878c97) chore(deps): bump github.com/posthog/posthog-ios from 3.62.0 to 3.64.1 (#848) by @app/dependabot
- [5936841](https://github.com/robinebers/openusage/commit/5936841f0dc9a278dd46329082008ccf272b978c) fix(claude): surface rate-limited state as a header warning instead of a silent blank (#849) by @robinebers
- [c8f3097](https://github.com/robinebers/openusage/commit/c8f30971419bf19bce6c7a7a711c72b087beb24a) docs: changelog for v0.7.3-beta.4 by @robinebers
- [2366bb3](https://github.com/robinebers/openusage/commit/2366bb3cd8d81d4f6efebb87925c935fc7b61a84) docs(skills): update Pages stall guidance for the Actions-based deploy by @robinebers
- [daccf05](https://github.com/robinebers/openusage/commit/daccf05a3d048e8fa4e9db0c2f96eff56f823f1d) feat(claude): include Cowork session logs in the local spend tiles (#845) by @robinebers
- [722e808](https://github.com/robinebers/openusage/commit/722e808b20a48288d3f57131195c58e2c6b2e751) docs: changelog for v0.7.3-beta.5 by @robinebers
- [4566101](https://github.com/robinebers/openusage/commit/4566101ba130f1fbf30f8b43126f87daa56412f7) ci: trigger Pages deploy from Release/pricing-supplement completion by @robinebers
- [c11f0d5](https://github.com/robinebers/openusage/commit/c11f0d578103b560dfbb8c6baf7ccc71fc43fba4) feat(dashboard): per-model spend breakdown on spend-row hover by @robinebers
- [5ea4ba4](https://github.com/robinebers/openusage/commit/5ea4ba4f059d30b50ce31852339e6d1e55cdb08c) style(dashboard): center the source-note footer in the breakdown and trend popovers by @robinebers
- [0d03230](https://github.com/robinebers/openusage/commit/0d03230e3d5d9214e0a84addd15804a21f013565) fix(dashboard): breakdown percentages always total 100; share the popover footer by @robinebers
- [f5f57ae](https://github.com/robinebers/openusage/commit/f5f57ae07085f80482f1f6ff0093ba4e3fc5c566) style(dashboard): one source-note string per provider across both popovers by @robinebers
- [1917874](https://github.com/robinebers/openusage/commit/191787453f507fb6170f94ba3cdaca1e6fa3c03a) docs: research notes behind the model breakdown hover design by @robinebers
- [9bbe86f](https://github.com/robinebers/openusage/commit/9bbe86fbfc37c195fa1e049bfc4c5bf6c6b2b5b4) fix(dashboard): trigger the model breakdown only on the value column by @robinebers
- [45b05c6](https://github.com/robinebers/openusage/commit/45b05c69ce2a31b6d8747b385ec9355ab17bbc3e) feat(customize): Reset All re-runs installed-tool detection by @robinebers
- [d3459af](https://github.com/robinebers/openusage/commit/d3459af2c1316e779de5815f7db26395ab3d4786) fix(spend): exclude unpriceable usage from every displayed total by @robinebers
- [88aa423](https://github.com/robinebers/openusage/commit/88aa423995b98f701ca294abda89eb91729106f9) feat(codex): status dot for reset-credit expiry by @robinebers
- [7462c08](https://github.com/robinebers/openusage/commit/7462c087774ca85714362d81e9426a7b7cacdaeb) docs: changelog for v0.7.3-beta.6 by @robinebers
- [88efe734](https://github.com/robinebers/openusage/commit/88efe73492c0c7416c25d907631a8c5dd81cb265) test(grok): split GrokProviderTests into per-class files by @validatedev
- [d94b5fb](https://github.com/robinebers/openusage/commit/d94b5fbb1b7bb8e6ccb34821ede33166c5931bc3) feat(grok): weekly shared-pool meter via the gRPC-web credits config by @validatedev
- [9b1357f](https://github.com/robinebers/openusage/commit/9b1357fbb30f9076a7c42c20cec69cf4537825e8) fix(grok): reject varints whose 10th byte overflows 64 bits by @validatedev
- [5fcb431](https://github.com/robinebers/openusage/commit/5fcb431225e62cb8db365b04fd63aa027507c146) refactor(grok): fetch weekly pool via the CLI's JSON credits endpoint, drop legacy monthly meter by @robinebers

## v0.7.3-beta.6

### New Features
- Per-model spend breakdown when hovering the Today / Yesterday / Last 30 Days rows ([#850](https://github.com/robinebers/openusage/pull/850)) by @robinebers
- Reset All re-detects installed tools ([#853](https://github.com/robinebers/openusage/pull/853)) by @robinebers
- Codex status dot for reset-credit expiry ([#854](https://github.com/robinebers/openusage/pull/854)) by @robinebers

### Bug Fixes
- Exclude unpriceable usage from every displayed spend total ([#853](https://github.com/robinebers/openusage/pull/853)) by @robinebers
- Model breakdown opens only from the value column; breakdown percentages always sum to 100 ([#850](https://github.com/robinebers/openusage/pull/850)) by @robinebers

### Chores
- Trigger Pages deploy from Release and pricing-supplement workflow completion by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.3-beta.5...v0.7.3-beta.6](https://github.com/robinebers/openusage/compare/v0.7.3-beta.5...v0.7.3-beta.6)

- [88aa423](https://github.com/robinebers/openusage/commit/88aa423995b98f701ca294abda89eb91729106f9) feat(codex): status dot for reset-credit expiry by @robinebers
- [d3459af](https://github.com/robinebers/openusage/commit/d3459af2c1316e779de5815f7db26395ab3d4786) fix(spend): exclude unpriceable usage from every displayed total by @robinebers
- [45b05c6](https://github.com/robinebers/openusage/commit/45b05c69ce2a31b6d8747b385ec9355ab17bbc3e) feat(customize): Reset All re-runs installed-tool detection by @robinebers
- [9bbe86f](https://github.com/robinebers/openusage/commit/9bbe86fbfc37c195fa1e049bfc4c5bf6c6b2b5b4) fix(dashboard): trigger the model breakdown only on the value column by @robinebers
- [1917874](https://github.com/robinebers/openusage/commit/191787453f507fb6170f94ba3cdaca1e6fa3c03a) docs: research notes behind the model breakdown hover design by @robinebers
- [f5f57ae](https://github.com/robinebers/openusage/commit/f5f57ae07085f80482f1f6ff0093ba4e3fc5c566) style(dashboard): one source-note string per provider across both popovers by @robinebers
- [0d03230](https://github.com/robinebers/openusage/commit/0d03230e3d5d9214e0a84addd15804a21f013565) fix(dashboard): breakdown percentages always total 100; share the popover footer by @robinebers
- [5ea4ba4](https://github.com/robinebers/openusage/commit/5ea4ba4f059d30b50ce31852339e6d1e55cdb08c) style(dashboard): center the source-note footer in the breakdown and trend popovers by @robinebers
- [c11f0d5](https://github.com/robinebers/openusage/commit/c11f0d578103b560dfbb8c6baf7ccc71fc43fba4) feat(dashboard): per-model spend breakdown on spend-row hover by @robinebers
- [4566101](https://github.com/robinebers/openusage/commit/4566101ba130f1fbf30f8b43126f87daa56412f7) ci: trigger Pages deploy from Release/pricing-supplement completion by @robinebers

## v0.7.3-beta.5

### New Features
- Include Cowork session logs in the Claude local spend tiles ([#845](https://github.com/robinebers/openusage/pull/845)) by @robinebers

### Chores
- Update skills' Pages stall guidance for the Actions-based deploy by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.3-beta.4...v0.7.3-beta.5](https://github.com/robinebers/openusage/compare/v0.7.3-beta.4...v0.7.3-beta.5)

- [daccf05](https://github.com/robinebers/openusage/commit/daccf05a3d048e8fa4e9db0c2f96eff56f823f1d) feat(claude): include Cowork session logs in the local spend tiles (#845) by @robinebers
- [2366bb3](https://github.com/robinebers/openusage/commit/2366bb3cd8d81d4f6efebb87925c935fc7b61a84) docs(skills): update Pages stall guidance for the Actions-based deploy by @robinebers

## v0.7.3-beta.4

### Bug Fixes
- fix(claude): surface rate-limited state as a header warning instead of a silent blank ([#849](https://github.com/robinebers/openusage/pull/849)) by @robinebers

### Chores
- chore(deps): bump github.com/posthog/posthog-ios from 3.62.0 to 3.64.1 ([#848](https://github.com/robinebers/openusage/pull/848)) by @app/dependabot
- chore(deps): bump actions/checkout from 4 to 7 ([#847](https://github.com/robinebers/openusage/pull/847)) by @app/dependabot

---

### Changelog
**Full Changelog**: [v0.7.3-beta.3...v0.7.3-beta.4](https://github.com/robinebers/openusage/compare/v0.7.3-beta.3...v0.7.3-beta.4)

- [5936841](https://github.com/robinebers/openusage/commit/5936841f0dc9a278dd46329082008ccf272b978c) fix(claude): surface rate-limited state as a header warning instead of a silent blank by @robinebers
- [0b8c39f](https://github.com/robinebers/openusage/commit/0b8c39f1ffeb61015f5deb6b91121d9083878c97) chore(deps): bump github.com/posthog/posthog-ios from 3.62.0 to 3.64.1 by @app/dependabot
- [9fa1923](https://github.com/robinebers/openusage/commit/9fa1923113de6205af83c7dd412ad07ccd77dc9b) chore(deps): bump actions/checkout from 4 to 7 by @app/dependabot

## v0.7.3-beta.3

### Bug Fixes
- fix(copilot): don't let a placeholder Extra Usage row block the org billing lookup ([#844](https://github.com/robinebers/openusage/pull/844)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.3-beta.2...v0.7.3-beta.3](https://github.com/robinebers/openusage/compare/v0.7.3-beta.2...v0.7.3-beta.3)

- [9709169](https://github.com/robinebers/openusage/commit/9709169108004785d34b7d5ecc1cccfd6fd2d8e2) fix(copilot): don't let a placeholder Extra Usage row block the org billing lookup by @robinebers

## v0.7.3-beta.2

### New Features
- feat(providers): credential-detect providers added by updates; unify installs on enabled-list mode ([#838](https://github.com/robinebers/openusage/pull/838)) by @robinebers
- feat(copilot): show org-level AI credit usage for org-managed Business/Enterprise seats ([#843](https://github.com/robinebers/openusage/pull/843)) by @robinebers
- feat(updates): in-popover update banner + Sparkle 2.9.4 focus fix ([#842](https://github.com/robinebers/openusage/pull/842)) by @robinebers
- feat(ui): replace footer split button with a single Options menu ([#841](https://github.com/robinebers/openusage/pull/841)) by @robinebers

### Bug Fixes
- fix(copilot): keep probing other orgs when one org's billing has an outage ([#843](https://github.com/robinebers/openusage/pull/843)) by @robinebers
- fix(notifications): open popover when a pace alert is tapped ([#840](https://github.com/robinebers/openusage/pull/840)) by @robinebers

### Refactor
- refactor(copilot): default both org billing metrics below the expand caret ([#843](https://github.com/robinebers/openusage/pull/843)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.3-beta.1...v0.7.3-beta.2](https://github.com/robinebers/openusage/compare/v0.7.3-beta.1...v0.7.3-beta.2)

- [b15a47e](https://github.com/robinebers/openusage/commit/b15a47ed6df02a5ce6eb0672ed5ffc5aac65e702) fix(copilot): keep probing other orgs when one org's billing has an outage by @robinebers
- [1171895](https://github.com/robinebers/openusage/commit/1171895a30ea2a5764ad6a9c65dbd8cd305b17b2) refactor(copilot): default both org billing metrics below the expand caret by @robinebers
- [8b567ae](https://github.com/robinebers/openusage/commit/8b567aeeb8f53d094dba8af79711e3eaff7679dc) feat(copilot): show org-level AI credit usage for org-managed Business/Enterprise seats by @robinebers
- [7cf5645](https://github.com/robinebers/openusage/commit/7cf564507738c4e4af06d6243e11a5c733dffc0c) feat(updates): in-popover update banner + Sparkle 2.9.4 focus fix by @robinebers
- [db821dd](https://github.com/robinebers/openusage/commit/db821dd2191e94a9a9443adf8af5bc41b21d0948) feat(ui): replace footer split button with a single Options menu by @robinebers
- [224c987](https://github.com/robinebers/openusage/commit/224c987c442a3d87ff14b4366835f7c683727dd4) Open the popover when a pace notification is tapped. by @robinebers
- [1b077d1](https://github.com/robinebers/openusage/commit/1b077d18b30f2cbbda2787735bb23020218e891e) feat(providers): credential-detect providers added by updates; unify installs on enabled-list mode by @robinebers

## v0.7.3-beta.1

### New Features
- feat(onboarding): fresh installs start with detected providers + welcome card ([#830](https://github.com/robinebers/openusage/pull/830)) by @robinebers
- feat(spend): native log scanners + dynamic model pricing, drop ccusage ([#827](https://github.com/robinebers/openusage/pull/827)) by @robinebers

### Bug Fixes
- fix(pricing): override Opus 4.7/4.8 fast-mode rates with Cursor's published pricing ([#835](https://github.com/robinebers/openusage/pull/835)) by @robinebers
- fix(claude): explain CLI login when only the desktop app is signed in ([#828](https://github.com/robinebers/openusage/pull/828)) by @robinebers
- fix(claude): only show desktop-app hint when no CLI credentials are stored ([#828](https://github.com/robinebers/openusage/pull/828)) by @robinebers
- fix(tests): port #828's desktop-app test off the removed CcusageRunner ([#834](https://github.com/robinebers/openusage/pull/834)) by @robinebers
- fix(tests): repair desktop-app-hint test broken by ccusage removal on main ([#830](https://github.com/robinebers/openusage/pull/830)) by @robinebers

### Chores
- docs: add pricing-update skill for syncing the pricing supplement ([#831](https://github.com/robinebers/openusage/pull/831)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.2...v0.7.3-beta.1](https://github.com/robinebers/openusage/compare/v0.7.2...v0.7.3-beta.1)

- [3c5882a](https://github.com/robinebers/openusage/commit/3c5882abb9a23cc85e7776395f0fd0130061c7ec) fix(pricing): override Opus 4.7/4.8 fast-mode rates with Cursor's published pricing by @robinebers
- [4fe8d17](https://github.com/robinebers/openusage/commit/4fe8d17a43a0dd8880a2311f6e8b4b5e73a1543c) fix(tests): port #828's desktop-app test off the removed CcusageRunner by @robinebers
- [e26b1c8](https://github.com/robinebers/openusage/commit/e26b1c83554933d86d585c9a4d2676a5a4cfcfa1) fix(tests): repair desktop-app-hint test broken by ccusage removal on main by @robinebers
- [59008dd](https://github.com/robinebers/openusage/commit/59008dddc2758f76df1d1a8c5ed4f4f170b49bcb) feat(onboarding): fresh installs start with detected providers + welcome card by @robinebers
- [7aeead1](https://github.com/robinebers/openusage/commit/7aeead1ca9e0615289b3e43bef3c5a594aa539b3) docs: add pricing-update skill for syncing the pricing supplement by @robinebers
- [5ea794a](https://github.com/robinebers/openusage/commit/5ea794a75d7a975c9f2cb7a3ef54dde0607ee13f) fix(claude): only show desktop-app hint when no CLI credentials are stored by @robinebers
- [be66c05](https://github.com/robinebers/openusage/commit/be66c0510eb3b4e7f66c5ab06a1ba0863988a7a7) fix(claude): explain CLI login when only the desktop app is signed in by @robinebers
- [68cc5c6](https://github.com/robinebers/openusage/commit/68cc5c6f712bda45490a16469119fcaab5256896) feat(spend): native log scanners + dynamic model pricing, drop ccusage by @robinebers

## v0.7.2

### New Features
- feat(popover): make Customize the primary footer button and cross-link the two screens by @robinebers
- feat(customize): add Reset All Customization button with confirmation ([#815](https://github.com/robinebers/openusage/pull/815)) by @robinebers
- feat(appearance): Increase Transparency toggle + secret-code Party/Drunk easter egg ([#784](https://github.com/robinebers/openusage/pull/784)) by @validatedev

### Bug Fixes
- fix(dashboard): open provider Customize from context menu on metrics by @robinebers
- fix(antigravity): rename pool rows to Session/Weekly for cross-provider consistency by @validatedev
- fix(codex): tolerate fetch latency in fresh-window detection so untouched sessions stop reading 99% left by @robinebers
- fix(antigravity): merged Gemini pool + weekly limits via RetrieveUserQuotaSummary by @validatedev
- fix(notifications): ignore reset timestamp jitter ([#816](https://github.com/robinebers/openusage/pull/816)) by @robinebers

### Chores
- chore(worktree-setup): exclude stale agent worktrees from rsync by @robinebers
- docs(release-swift): stable changelogs span last-stable to this-stable by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1...v0.7.2](https://github.com/robinebers/openusage/compare/v0.7.1...v0.7.2)

- [ed7ef3c](https://github.com/robinebers/openusage/commit/ed7ef3c9393b1ffb14c7aad87cf7423773c1e8d7) chore(worktree-setup): exclude stale agent worktrees from rsync by @robinebers
- [a16ee82](https://github.com/robinebers/openusage/commit/a16ee828e2f1f12df9ff1a572d1cb6d586d9e331) fix(dashboard): open provider Customize from context menu on metrics by @robinebers
- [7ab9208](https://github.com/robinebers/openusage/commit/7ab92087fde58915ea2d2fc5b540cfce5f369d95) fix(antigravity): rename pool rows to Session/Weekly for cross-provider consistency by @validatedev
- [a090ba6](https://github.com/robinebers/openusage/commit/a090ba60b08c29a3b66d2cbeec31b4a503b421bb) fix(codex): tolerate fetch latency in fresh-window detection so untouched sessions stop reading 99% left by @robinebers
- [1ce97bc](https://github.com/robinebers/openusage/commit/1ce97bcc7955e72d95a981c5dde971546264a8ae) fix(antigravity): merged Gemini pool + weekly limits via RetrieveUserQuotaSummary by @validatedev
- [d7411a8](https://github.com/robinebers/openusage/commit/d7411a8d8c78fa72a2d5309878c41bf58b5e2e8a) feat(popover): make Customize the primary footer button and cross-link the two screens by @robinebers
- [d152b09](https://github.com/robinebers/openusage/commit/d152b090d5707adfcb920de2ca2b597355df0b34) fix(notifications): ignore reset timestamp jitter (#816) by @robinebers
- [21a109a](https://github.com/robinebers/openusage/commit/21a109ab4e963a1529caeccacf175bc092308dab) feat(customize): add Reset All Customization button with confirmation (#815) by @robinebers
- [6e513ec](https://github.com/robinebers/openusage/commit/6e513eccf47bea8527420f8cdfc7fcc50702029f) feat(appearance): Increase Transparency toggle + secret-code Party/Drunk easter egg (#784) by @validatedev
- [6aca8aa](https://github.com/robinebers/openusage/commit/6aca8aa1030bf9e4d11292bfd5c5b0205754ee2e) docs(release-swift): stable changelogs span last-stable to this-stable by @robinebers

## v0.7.1

### New Features
- feat(claude): track Fable model-scoped weekly limit from the limits array ([#814](https://github.com/robinebers/openusage/pull/814)) by @robinebers
- feat(copilot): track AI Credits + Extra Usage; fix paid quota rendering ([#807](https://github.com/robinebers/openusage/pull/807)) by @robinebers
- feat(codex): bring back GPT-5.3-Codex-Spark rate-limit meters ([#796](https://github.com/robinebers/openusage/pull/806)) by @robinebers
- feat(zai): add Z.ai provider for GLM Coding Plan usage tracking ([#783](https://github.com/robinebers/openusage/pull/793)) by @robinebers
- feat(openrouter): add OpenRouter usage provider ([#763](https://github.com/robinebers/openusage/pull/763)) by @robinebers
- feat(copilot): add GitHub Copilot usage provider ([#764](https://github.com/robinebers/openusage/pull/764)) by @robinebers
- feat(notifications): quota pace alerts — 3 triggers, launch-prime, per-app stacking ([#633](https://github.com/robinebers/openusage/pull/786)) by @robinebers
- feat(cursor): re-enable spend tracking + warn on unknown-model spend ([#789](https://github.com/robinebers/openusage/pull/789)) by @robinebers
- feat(cursor): price GLM 5.2 in the spend manifest ([#781](https://github.com/robinebers/openusage/pull/781)) by @robinebers
- feat(share): per-provider Copy as Image card ([#762](https://github.com/robinebers/openusage/pull/778)) by @robinebers
- feat(share): Share Screenshot footer submenu + copied-to-clipboard pill ([#785](https://github.com/robinebers/openusage/pull/785)) by @robinebers
- feat(providers): bring back provider quick-link buttons ([#596](https://github.com/robinebers/openusage/pull/779)) by @robinebers
- feat(providers): add quick-link buttons for Devin and Copilot ([#799](https://github.com/robinebers/openusage/pull/799)) by @robinebers
- feat(openrouter): add Activity and Credits quick-link buttons ([#795](https://github.com/robinebers/openusage/pull/795)) by @robinebers
- feat(customize): undo widget removal ([#603](https://github.com/robinebers/openusage/pull/771)) by @robinebers
- Customize: provider list → detail, on/off + API keys in Customize, stars ([#797](https://github.com/robinebers/openusage/pull/797)) by @robinebers

### Bug Fixes
- fix(cursor): price Claude Sonnet 5 in spend imputation manifest ([#813](https://github.com/robinebers/openusage/pull/813)) by @robinebers
- fix: dynamic widget height for single-provider users ([#800](https://github.com/robinebers/openusage/pull/810)) by @robinebers
- fix(claude): surface re-login warning when login lacks user:profile scope ([#782](https://github.com/robinebers/openusage/pull/794)) by @robinebers
- fix(spend): no-usage period reads "No data" for every provider ([#790](https://github.com/robinebers/openusage/pull/790)) by @robinebers
- fix(providers): resolve env-var API keys from the login shell in packaged builds ([#788](https://github.com/robinebers/openusage/pull/788)) by @robinebers
- fix(codex): refresh OAuth token by JWT exp, not a hardcoded 8-day age ([#516](https://github.com/robinebers/openusage/pull/769)) by @robinebers
- fix(antigravity): show "Not started" for unused 5-hour quota pools ([#761](https://github.com/robinebers/openusage/pull/761)) by @robinebers
- fix(tests): allow OpenRouter Activity/Credits quick-link labels ([#805](https://github.com/robinebers/openusage/pull/805)) by @robinebers

### Chores
- chore(notifications): debug-log each pace-notification decision ([#811](https://github.com/robinebers/openusage/pull/811)) by @robinebers
- chore: strict issue-first PR policy + faster stale + AGENTS-aligned PR template ([#804](https://github.com/robinebers/openusage/pull/804)) by @robinebers
- chore(codex): drop parsing of retired per-model and review rate limits by @robinebers
- chore(deps): bump github.com/sindresorhus/keyboardshortcuts ([#766](https://github.com/robinebers/openusage/pull/766)) by @dependabot[bot]
- chore(deps): bump actions/checkout from 6 to 7 ([#765](https://github.com/robinebers/openusage/pull/765)) by @dependabot[bot]
- docs: restore README hero screenshot and trailing newline by @robinebers
- docs: add Installation section with Homebrew cask and latest release DMG by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.0...v0.7.1](https://github.com/robinebers/openusage/compare/v0.7.0...v0.7.1)

## v0.7.1-beta.7

### Bug Fixes
- cursor: price Claude Sonnet 5 in spend imputation manifest ([#813](https://github.com/robinebers/openusage/pull/813)) by @robinebers
- Dynamic widget height for single-provider users ([#810](https://github.com/robinebers/openusage/pull/810)) by @robinebers

### Chores
- notifications: debug-log each pace-notification decision ([#811](https://github.com/robinebers/openusage/pull/811)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1-beta.6...v0.7.1-beta.7](https://github.com/robinebers/openusage/compare/v0.7.1-beta.6...v0.7.1-beta.7)

- [e56c360](https://github.com/robinebers/openusage/commit/e56c360b230924658da36f8ac16fdce06add29ab) chore(notifications): debug-log each pace-notification decision (#811) by @robinebers
- [f0aacfc](https://github.com/robinebers/openusage/commit/f0aacfca006ced72ef5ca086d27dbe5a75bea381) fix(cursor): price Claude Sonnet 5 in spend imputation manifest (#813) by @robinebers
- [0ebd9e4](https://github.com/robinebers/openusage/commit/0ebd9e44a81d3063da583158fe31abf1cbb5b38a) fix: dynamic widget height for single-provider users (#800) (#810) by @robinebers

## v0.7.1-beta.6

### New Features
- copilot: track AI Credits + Extra Usage; fix paid quota rendering ([#807](https://github.com/robinebers/openusage/pull/807)) by @robinebers
- codex: bring back GPT-5.3-Codex-Spark rate-limit meters ([#806](https://github.com/robinebers/openusage/pull/806)) by @robinebers
- openrouter: add Activity and Credits quick-link buttons ([#795](https://github.com/robinebers/openusage/pull/795)) by @robinebers
- providers: add quick-link buttons for Devin and Copilot ([#799](https://github.com/robinebers/openusage/pull/799)) by @robinebers
- Customize: provider list → detail, on/off + API keys in Customize, stars ([#797](https://github.com/robinebers/openusage/pull/797)) by @robinebers

### Bug Fixes
- tests: allow OpenRouter Activity/Credits quick-link labels ([#805](https://github.com/robinebers/openusage/pull/805)) by @robinebers

### Chores
- strict issue-first PR policy + faster stale + AGENTS-aligned PR template ([#804](https://github.com/robinebers/openusage/pull/804)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1-beta.5...v0.7.1-beta.6](https://github.com/robinebers/openusage/compare/v0.7.1-beta.5...v0.7.1-beta.6)

- [c6e4cb9](https://github.com/robinebers/openusage/commit/c6e4cb95137d9d0be3d953d6f512628153054265) feat(copilot): track AI Credits + Extra Usage; fix paid quota rendering (#807) by @robinebers
- [149dcd9](https://github.com/robinebers/openusage/commit/149dcd94ef00968826a2427a79be23a335e40b23) feat(codex): bring back GPT-5.3-Codex-Spark rate-limit meters (#796) (#806) by @robinebers
- [5452c3f](https://github.com/robinebers/openusage/commit/5452c3f4ae7efdd852683b62889c33f2f114a47b) fix(tests): allow OpenRouter Activity/Credits quick-link labels (#805) by @robinebers
- [7a5daaa](https://github.com/robinebers/openusage/commit/7a5daaa3dc307244a48bcb539941996c93e1557e) chore: strict issue-first PR policy + faster stale + AGENTS-aligned PR template (#804) by @robinebers
- [807ee3f](https://github.com/robinebers/openusage/commit/807ee3f1bfd15f9528c59d4bc10102645d3809b3) feat(openrouter): add Activity and Credits quick-link buttons (#795) by @robinebers
- [402824d](https://github.com/robinebers/openusage/commit/402824d9cafb7fa47585c2c3621a212d9d7e8c9c) feat(providers): add quick-link buttons for Devin and Copilot (#799) by @robinebers
- [2fccb51](https://github.com/robinebers/openusage/commit/2fccb5127fff7b86d13b728f9f0b45ffd167e3d6) Customize: provider list → detail, on/off + API keys in Customize, stars (#797) by @robinebers

## v0.7.1-beta.5

### New Features
- Add Z.ai provider for GLM Coding Plan usage tracking ([#793](https://github.com/robinebers/openusage/pull/793)) by @robinebers

### Bug Fixes
- Surface re-login warning when Claude login lacks the user:profile scope ([#794](https://github.com/robinebers/openusage/pull/794)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1-beta.4...v0.7.1-beta.5](https://github.com/robinebers/openusage/compare/v0.7.1-beta.4...v0.7.1-beta.5)

- [9790407](https://github.com/robinebers/openusage/commit/9790407efcdd0c2a1775d7779d46eecd1d675be4) feat(zai): add Z.ai provider for GLM Coding Plan usage tracking (#783) (#793) by @robinebers
- [e040e86](https://github.com/robinebers/openusage/commit/e040e86241f453323027e131c7fbeed257b9644b) fix(claude): surface re-login warning when login lacks user:profile scope (#782) (#794) by @robinebers

## v0.7.1-beta.4

### New Features
- Re-enable Cursor spend tracking and warn on unknown-model spend ([#789](https://github.com/robinebers/openusage/pull/789)) by @robinebers

### Bug Fixes
- No-usage period reads "No data" for every provider ([#790](https://github.com/robinebers/openusage/pull/790)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1-beta.3...v0.7.1-beta.4](https://github.com/robinebers/openusage/compare/v0.7.1-beta.3...v0.7.1-beta.4)

- [9f5eb51](https://github.com/robinebers/openusage/commit/9f5eb51bcdaa01a7612ad0cd0ef557325fdfcb99) feat(cursor): re-enable spend tracking + warn on unknown-model spend (#789) by @robinebers
- [028c25c](https://github.com/robinebers/openusage/commit/028c25cf686b17c439e19192b3e5a1a466c7f887) fix(spend): no-usage period reads "No data" for every provider (#790) by @robinebers

## v0.7.1-beta.3

### Bug Fixes
- Resolve env-var API keys (e.g. `OPENROUTER_API_KEY`) from the login shell in packaged builds, and remove the "Stored in …" caption from the API Keys editor ([#788](https://github.com/robinebers/openusage/pull/788)) by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1-beta.2...v0.7.1-beta.3](https://github.com/robinebers/openusage/compare/v0.7.1-beta.2...v0.7.1-beta.3)

- [8d0b6c7](https://github.com/robinebers/openusage/commit/8d0b6c74415a644ef4f39258433df1da261fae25) fix(providers): resolve env-var API keys from the login shell in packaged builds (#788) by @robinebers

## v0.7.1-beta.2

### New Features
- Add OpenRouter usage provider ([#763](https://github.com/robinebers/openusage/pull/763)) by @robinebers
- Quota pace alerts — 3 triggers, launch-prime, per-app stacking ([#786](https://github.com/robinebers/openusage/pull/786)) by @robinebers
- Share Screenshot footer submenu + copied-to-clipboard pill ([#785](https://github.com/robinebers/openusage/pull/785)) by @robinebers

### Bug Fixes
- Refresh Codex OAuth token by JWT exp, not a hardcoded 8-day age ([#769](https://github.com/robinebers/openusage/pull/769)) by @robinebers

### Chores
- Drop parsing of retired Codex per-model and review rate limits by @robinebers
- Restore README hero screenshot and trailing newline by @robinebers
- Add Installation section with Homebrew cask and latest release DMG by @robinebers

---

### Changelog
**Full Changelog**: [v0.7.1-beta.1...v0.7.1-beta.2](https://github.com/robinebers/openusage/compare/v0.7.1-beta.1...v0.7.1-beta.2)

- [386fcfe](https://github.com/robinebers/openusage/commit/386fcfeb3186ec9f3fe3bd43a8c7d7a4db8efd21) chore(codex): drop parsing of retired per-model and review rate limits by @robinebers
- [8360e93](https://github.com/robinebers/openusage/commit/8360e93717c3af04ff27cf49cd1d7274693dac4f) feat(openrouter): add OpenRouter usage provider (#763) by @robinebers
- [1cf2eb4](https://github.com/robinebers/openusage/commit/1cf2eb4f418299707aac50b60df324c1556a2374) feat(notifications): quota pace alerts — 3 triggers, launch-prime, per-app stacking (#633) (#786) by @robinebers
- [fd0890e](https://github.com/robinebers/openusage/commit/fd0890ef65536ffdd4875e7a75a1531850f70ba1) feat(share): Share Screenshot footer submenu + copied-to-clipboard pill (#785) by @robinebers
- [b50efbb](https://github.com/robinebers/openusage/commit/b50efbb41f71520112be32f823c896de34813823) docs: restore README hero screenshot and trailing newline by @robinebers
- [2eada69](https://github.com/robinebers/openusage/commit/2eada69bc904e9268264713bc87761afe94f8f7a) docs: add Installation section with Homebrew cask and latest release DMG by @robinebers
- [42ce1e2](https://github.com/robinebers/openusage/commit/42ce1e2cde443d443dde59c9ccd941adf26af44b) fix(codex): refresh OAuth token by JWT exp, not a hardcoded 8-day age (#516) (#769) by @robinebers

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
