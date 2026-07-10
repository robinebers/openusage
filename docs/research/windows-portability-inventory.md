# Windows Portability Inventory

Status: Phase 1 Task A — generated 2026-07-10 from import scan + dependency analysis of `Sources/OpenUsage/` (198 files) and `Tests/OpenUsageTests/` (98 files).

Categories:

1. **PORTABLE-AS-IS** — Foundation-only, no patches needed
2. **PORTABLE-AFTER-SEAM** — small mechanical patch (seam named)
3. **MACOS-ADAPTER** — stays macOS-only behind a protocol
4. **WINDOWS-ADAPTER-NEEDED** — Windows twin required (API named)
5. **UI-SHELL** — SwiftUI/AppKit view layer; respec in Windows shell

## App/ (15 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `AppContainer.swift` | PORTABLE-AFTER-SEAM | Composition root; inject LoginShellEnvironment + AppNotifications on macOS | Foundation, Observation |
| `FirstRunSeeder.swift` | PORTABLE-AS-IS | — | Foundation |
| `LegacyLaunchAgentCleanup.swift` | MACOS-ADAPTER | LaunchAgents + Bundle.main | Foundation |
| `NewProviderSeeder.swift` | PORTABLE-AS-IS | — | Foundation |
| `OpenUsageApp.swift` | UI-SHELL | App entry + NSApplicationDelegate | AppKit, SwiftUI |
| `PanelHeightController.swift` | MACOS-ADAPTER | NSWindow frame morphing | AppKit |
| `PanelOutsideClickMonitor.swift` | MACOS-ADAPTER | NSEvent global monitor | AppKit |
| `PopoverBackdropView.swift` | MACOS-ADAPTER | NSView backdrop | AppKit |
| `RefreshWakeSignal.swift` | PORTABLE-AS-IS | — | Foundation |
| `SettingsMigrator.swift` | PORTABLE-AFTER-SEAM | Bundle.main domainName defaults → app-metadata seam | Foundation |
| `SingleInstanceGuard.swift` | MACOS-ADAPTER | NSRunningApplication activation | AppKit, Darwin |
| `SingleInstanceLock.swift` | WINDOWS-ADAPTER-NEEDED | flock → CreateMutex/named mutex | Darwin, Foundation |
| `StatusItemController.swift` | UI-SHELL | NSStatusItem + NSPanel shell | AppKit, KeyboardShortcuts, SwiftUI |
| `StatusItemImageUpdater.swift` | MACOS-ADAPTER | NSStatusItem image | AppKit, Observation |
| `UpdaterController.swift` | MACOS-ADAPTER | Sparkle SPUUpdater | AppKit, Combine, Foundation, Observation, Sparkle |

**Directory totals:** PORTABLE-AS-IS: 3, PORTABLE-AFTER-SEAM: 2, MACOS-ADAPTER: 7, WINDOWS-ADAPTER-NEEDED: 1, UI-SHELL: 2

## Models/ (15 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `DailyUsageSeries.swift` | PORTABLE-AS-IS | — | Foundation |
| `DashboardLayout.swift` | PORTABLE-AS-IS | — | Foundation |
| `MenuBarContent.swift` | PORTABLE-AFTER-SEAM | IconSource extraction (Phase 0 patch #4) | Foundation |
| `MenuBarStyle.swift` | PORTABLE-AS-IS | — | Foundation |
| `MetricKind.swift` | PORTABLE-AS-IS | — | Foundation |
| `MetricLine.swift` | PORTABLE-AS-IS | — | Foundation |
| `MetricValue.swift` | PORTABLE-AS-IS | — | Foundation |
| `PlanWidget.swift` | PORTABLE-AFTER-SEAM | Remove SwiftUI import; platform-neutral plan type | SwiftUI |
| `Provider.swift` | PORTABLE-AFTER-SEAM | IconSource extraction (Phase 0 patch #4) | Foundation |
| `ProviderSnapshot.swift` | PORTABLE-AS-IS | — | Foundation |
| `ResetDisplayMode.swift` | PORTABLE-AS-IS | — | Foundation |
| `WidgetData.swift` | PORTABLE-AFTER-SEAM | IconSource extraction (Phase 0 patch #4) | Foundation |
| `WidgetDescriptor+Factories.swift` | PORTABLE-AS-IS | — | Foundation |
| `WidgetDescriptor.swift` | PORTABLE-AS-IS | — | Foundation |
| `WidgetDisplayMode.swift` | PORTABLE-AS-IS | — | Foundation |

**Directory totals:** PORTABLE-AS-IS: 11, PORTABLE-AFTER-SEAM: 4

## Pricing/ (6 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `ModelPricing.swift` | PORTABLE-AFTER-SEAM | OSAllocatedUnfairLock → NSLock (Phase 0 patch #1) | Foundation, os |
| `ModelPricingStore.swift` | PORTABLE-AFTER-SEAM | WellKnownPaths for cache dir (Phase 0 patch #11) | Foundation |
| `ModelRates.swift` | PORTABLE-AS-IS | — | Foundation |
| `PricingCatalog.swift` | PORTABLE-AS-IS | — | Foundation |
| `PricingCatalogCodecs.swift` | PORTABLE-AS-IS | — | Foundation |
| `PricingSupplement.swift` | PORTABLE-AS-IS | — | Foundation |

**Directory totals:** PORTABLE-AS-IS: 4, PORTABLE-AFTER-SEAM: 2

## Providers/ (56 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `APIKeyManagement.swift` | PORTABLE-AS-IS | — | Foundation |
| `AntigravityAuthStore.swift` | PORTABLE-AFTER-SEAM | CredentialStoreAccessing; WellKnownPaths | Foundation |
| `AntigravityErrors.swift` | PORTABLE-AS-IS | — | Foundation |
| `AntigravityMetric.swift` | PORTABLE-AS-IS | — | Foundation |
| `AntigravityProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `AntigravityUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `AntigravityUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `ClaudeAuthStore.swift` | PORTABLE-AFTER-SEAM | CryptoKit → swift-crypto; keychain stub; WellKnownPaths | CryptoKit, Foundation |
| `ClaudeLogUsageScanner.swift` | PORTABLE-AS-IS | — | Foundation |
| `ClaudeProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `ClaudeUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `ClaudeUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `CodexAuthStore.swift` | PORTABLE-AFTER-SEAM | Keychain stub; WellKnownPaths for auth paths | Foundation |
| `CodexLogUsageScanner.swift` | PORTABLE-AS-IS | — | Foundation |
| `CodexProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `CodexUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `CodexUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `CopilotAuthStore.swift` | PORTABLE-AFTER-SEAM | CredentialStoreAccessing; go-keyring unwrap | Foundation |
| `CopilotOrgBillingClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `CopilotOrgBillingMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `CopilotProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `CopilotUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `CopilotUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `CursorAuthStore.swift` | PORTABLE-AFTER-SEAM | SQLiteAccessing + CredentialStore; WellKnownPaths | Foundation |
| `CursorCSVParser.swift` | PORTABLE-AS-IS | — | Foundation |
| `CursorProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `CursorUsageCSV.swift` | PORTABLE-AS-IS | — | Foundation |
| `CursorUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `CursorUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `DailyUsageAccumulator.swift` | PORTABLE-AS-IS | — | Foundation |
| `DevinAuthStore.swift` | PORTABLE-AFTER-SEAM | SQLiteAccessing; WellKnownPaths | Foundation |
| `DevinProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `DevinUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `DevinUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `ErrorCategory.swift` | PORTABLE-AS-IS | — | Foundation |
| `GrokAuthStore.swift` | PORTABLE-AFTER-SEAM | WellKnownPaths for ~/.grok (Phase 0 proven) | Foundation |
| `GrokCreditsConfigDecoder.swift` | PORTABLE-AS-IS | — | Foundation |
| `GrokLogUsageScanner.swift` | PORTABLE-AS-IS | — | Foundation |
| `GrokProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `GrokUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `GrokUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `IncrementalJSONLScanner.swift` | PORTABLE-AFTER-SEAM | Injectable filesystem seam; shared-read on Windows | Foundation |
| `OpenRouterAuthStore.swift` | PORTABLE-AS-IS | Env + config file only | Foundation |
| `OpenRouterProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `OpenRouterUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `OpenRouterUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `ProviderAuthRetry.swift` | PORTABLE-AS-IS | — | Foundation |
| `ProviderRuntime.swift` | PORTABLE-AS-IS | — | Foundation |
| `ProviderUsageErrorText.swift` | PORTABLE-AS-IS | — | Foundation |
| `SpendTileMapper.swift` | PORTABLE-AS-IS | — | Foundation |
| `UsageLogReadFailureReporter.swift` | PORTABLE-AS-IS | — | Foundation |
| `UserAPIKeyStore.swift` | PORTABLE-AS-IS | — | Foundation |
| `ZAIAuthStore.swift` | PORTABLE-AS-IS | Env + config file only | Foundation |
| `ZAIProvider.swift` | PORTABLE-AS-IS | — | Foundation |
| `ZAIUsageClient.swift` | PORTABLE-AS-IS | — | Foundation |
| `ZAIUsageMapper.swift` | PORTABLE-AS-IS | — | Foundation |

**Directory totals:** PORTABLE-AS-IS: 48, PORTABLE-AFTER-SEAM: 8

## Services/ (9 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `HTTPClient.swift` | PORTABLE-AFTER-SEAM | FoundationNetworking guard; TLS delegate (Phase 0 #17) | Foundation |
| `LanguageServerDiscovery.swift` | WINDOWS-ADAPTER-NEEDED | ps/lsof → Toolhelp32/GetExtendedTcpTable | Foundation |
| `LocalUsageAPI.swift` | PORTABLE-AS-IS | — | Foundation |
| `LocalUsageServer.swift` | WINDOWS-ADAPTER-NEEDED | NWListener → portable socket transport | Foundation, Network |
| `LoginShellEnvironment.swift` | MACOS-ADAPTER | /usr/bin/env login-shell capture | Foundation |
| `ProcessRunner.swift` | WINDOWS-ADAPTER-NEEDED | Darwin kill/pgrep → CreateProcess/Toolhelp32 | Foundation, Darwin |
| `ProxyConfig.swift` | PORTABLE-AFTER-SEAM | Network/ProxyConfiguration stub (Phase 0 #7/#18) | Foundation, Network |
| `SystemClients.swift` | MACOS-ADAPTER | SecurityKeychainAccessor + SQLiteCLIAccessor | Foundation |
| `Telemetry.swift` | MACOS-ADAPTER | PostHog iOS SDK → HTTP API seam | Foundation, PostHog |

**Directory totals:** PORTABLE-AS-IS: 1, PORTABLE-AFTER-SEAM: 2, MACOS-ADAPTER: 3, WINDOWS-ADAPTER-NEEDED: 3

## Stores/ (27 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `AppearanceSetting.swift` | MACOS-ADAPTER | NSAppearance | AppKit |
| `DefaultLayout.swift` | PORTABLE-AS-IS | — | Foundation |
| `DensitySetting.swift` | MACOS-ADAPTER | NSFont metrics | AppKit |
| `LaunchAtLoginSetting.swift` | MACOS-ADAPTER | ServiceManagement SMAppService | Observation, ServiceManagement |
| `LayoutBootstrap.swift` | PORTABLE-AS-IS | — | Foundation |
| `LayoutPersistence.swift` | PORTABLE-AS-IS | — | Foundation |
| `LayoutStore.swift` | PORTABLE-AFTER-SEAM | Remove SwiftUI; platform-neutral layout state | SwiftUI, Observation |
| `LayoutUndoHistory.swift` | PORTABLE-AS-IS | — | Foundation |
| `LogLevelSetting.swift` | PORTABLE-AS-IS | — | Foundation |
| `NotificationSettingsStore.swift` | PORTABLE-AS-IS | — | Foundation, Observation |
| `OnboardingStore.swift` | PORTABLE-AS-IS | — | Foundation, Observation |
| `PopoverNavigationStore.swift` | PORTABLE-AS-IS | — | Observation |
| `PopoverTransparencyStore.swift` | MACOS-ADAPTER | NSVisualEffectView material | AppKit, Observation |
| `PopoverTransparencyStyle.swift` | PORTABLE-AS-IS | CoreGraphics-only opacity math | CoreGraphics |
| `ProviderEnablementStore.swift` | PORTABLE-AS-IS | — | Foundation, Observation |
| `ProviderSnapshotCache.swift` | PORTABLE-AFTER-SEAM | OSAllocatedUnfairLock → NSLock | Foundation, os |
| `QuotaNotificationEvaluator.swift` | PORTABLE-AS-IS | — | Foundation |
| `RefreshSetting.swift` | PORTABLE-AS-IS | — | Foundation |
| `SecretCodeMatcher.swift` | PORTABLE-AS-IS | — | Foundation |
| `TelemetryRecorder.swift` | PORTABLE-AFTER-SEAM | Bundle.main version → app-metadata seam | Foundation |
| `TelemetryStore.swift` | PORTABLE-AFTER-SEAM | Bundle.main suiteName → app-metadata seam | Foundation |
| `TimeFormatSetting.swift` | PORTABLE-AS-IS | — | Foundation |
| `TotalSpendSetting.swift` | PORTABLE-AS-IS | — | Foundation |
| `TransientNotice.swift` | PORTABLE-AS-IS | — | Observation |
| `UserDefaultsBacked.swift` | PORTABLE-AS-IS | — | Foundation |
| `WidgetDataStore.swift` | PORTABLE-AFTER-SEAM | Inject notification seam (defaults AppNotifications.shared) | Foundation, Observation |
| `WidgetRegistry.swift` | PORTABLE-AS-IS | — | Foundation |

**Directory totals:** PORTABLE-AS-IS: 18, PORTABLE-AFTER-SEAM: 5, MACOS-ADAPTER: 4

## Support/ (30 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `AboutPanel.swift` | MACOS-ADAPTER | NSPanel about box | AppKit |
| `Animations.swift` | UI-SHELL | SwiftUI rendering/view code | SwiftUI |
| `AppInfo.swift` | PORTABLE-AFTER-SEAM | Static version / app-metadata seam (Phase 0 patch #10) | Foundation |
| `AppLog.swift` | PORTABLE-AFTER-SEAM | os.Logger → portable sink (Phase 0 patch #2) | Foundation, os |
| `AppNotifications.swift` | MACOS-ADAPTER | UNUserNotificationCenter + AppKit | AppKit, Foundation, UserNotifications |
| `AppShortcuts.swift` | MACOS-ADAPTER | KeyboardShortcuts dependency | KeyboardShortcuts |
| `Formatters.swift` | PORTABLE-AS-IS | — | Foundation |
| `Haptics.swift` | MACOS-ADAPTER | NSHapticFeedbackManager | AppKit |
| `InvisibleOverlayScroller.swift` | MACOS-ADAPTER | AppKit support code | SwiftUI, AppKit |
| `LiquidGlassFallbacks.swift` | UI-SHELL | SwiftUI rendering/view code | SwiftUI |
| `LogFile.swift` | PORTABLE-AFTER-SEAM | WellKnownPaths log dir (Phase 0 patch #3) | Foundation, os |
| `LogRedaction.swift` | PORTABLE-AS-IS | — | Foundation |
| `MenuBarIcon.swift` | UI-SHELL | NSImage status icon | AppKit, SwiftUI |
| `MenuBarStripRenderer.swift` | UI-SHELL | Menu bar metric strip rendering | AppKit, SwiftUI |
| `MetricFormatter.swift` | PORTABLE-AS-IS | — | Foundation |
| `MetricPeriod.swift` | PORTABLE-AS-IS | — | Foundation |
| `OpenUsageISO8601.swift` | PORTABLE-AS-IS | — | Foundation |
| `Pace.swift` | PORTABLE-AS-IS | — | Foundation |
| `PaceNotificationLogic.swift` | PORTABLE-AS-IS | — | Foundation |
| `PartyMode.swift` | UI-SHELL | SwiftUI rendering/view code | SwiftUI |
| `PopoverDismissReader.swift` | MACOS-ADAPTER | AppKit support code | SwiftUI, AppKit |
| `PopoverSurfaceTreatment.swift` | UI-SHELL | SwiftUI rendering/view code | SwiftUI |
| `ProviderIconShape.swift` | UI-SHELL | SwiftUI icon rendering; IconSource moves to core | SwiftUI |
| `ProviderParse.swift` | PORTABLE-AS-IS | — | Foundation |
| `ResourceBundle.swift` | PORTABLE-AFTER-SEAM | Bundle.module lookup (Phase 0 patch #9) | Foundation |
| `ShareCardRenderer.swift` | UI-SHELL | NSImage render from SwiftUI | AppKit, SwiftUI |
| `Theme.swift` | MACOS-ADAPTER | AppKit support code | SwiftUI, AppKit |
| `TooMuchTransparencyEffect.swift` | UI-SHELL | SwiftUI rendering/view code | SwiftUI |
| `TooMuchTransparencyKeyReader.swift` | MACOS-ADAPTER | AppKit support code | SwiftUI, AppKit |
| `TotalSpendAggregator.swift` | PORTABLE-AS-IS | — | Foundation |

**Directory totals:** PORTABLE-AS-IS: 9, PORTABLE-AFTER-SEAM: 4, MACOS-ADAPTER: 8, UI-SHELL: 9

## Views/ (40 files)

| File | Category | Seam / Notes | Imports |
|---|---|---|---|
| `APIKeysSection.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI, AppKit |
| `ClosureMenuItem.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit |
| `CustomizeHintCard.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `CustomizeProviderDetailView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `CustomizeProviderListView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `CustomizeRow.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `CustomizeView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `DashboardContentView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `DashboardView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI, AppKit |
| `DismissableHintCard.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `HeaderView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, SwiftUI |
| `HoverPopoverState.swift` | PORTABLE-AS-IS | — | Foundation |
| `HoverTooltip.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, SwiftUI |
| `ModelUsageDetail.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, SwiftUI |
| `PanelHeightCoordinator.swift` | PORTABLE-AS-IS | CoreGraphics height math | CoreGraphics, Observation |
| `PanelHeightModifier.swift` | UI-SHELL | SwiftUI modifier + os lock | SwiftUI, os |
| `PopoverFooter.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `PopoverScrollView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `PopoverSourceNote.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `PopoverTopBar.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ProviderCard.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ProviderLinksView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, SwiftUI |
| `ProviderListRow.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ProviderSectionHeader.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `RateLimitResetsDetail.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ReorderGeometry.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `RingSectorShape.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ScreenCrossLink.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `SettingsScreen.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, Combine, KeyboardShortcuts, SwiftUI, UserNotifications |
| `ShareCardChrome.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ShareCardView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `ShortcutRecorderField.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, Carbon, KeyboardShortcuts, SwiftUI |
| `TotalSpendCard.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, SwiftUI |
| `TotalSpendShareCardView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `TransientPill.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `UpdateBannerCard.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `UsageSparkline.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `UsageTrendDetail.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `WidgetGroupedListView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | SwiftUI |
| `WidgetRowView.swift` | UI-SHELL | SwiftUI view layer — respec in Windows shell | AppKit, SwiftUI |

**Directory totals:** PORTABLE-AS-IS: 2, UI-SHELL: 38

## Tests/OpenUsageTests/ (98 files)

| File | Classification |
|---|---|
| `AntigravityLayoutTests.swift` | macos-only |
| `AntigravityProviderTests.swift` | core-portable |
| `AntigravityQuotaSummaryTests.swift` | core-portable |
| `AppLogTests.swift` | needs-windows-fixture |
| `AppNotificationsTests.swift` | macos-only |
| `ClaudeLogUsageScannerTests.swift` | core-portable |
| `ClaudeProviderTests.swift` | core-portable |
| `CodexLogUsageScannerTests.swift` | core-portable |
| `CodexProviderTests.swift` | core-portable |
| `CopilotProviderTests.swift` | core-portable |
| `CursorProviderTests.swift` | core-portable |
| `CursorSpendTests.swift` | core-portable |
| `DailyUsageAccumulatorTests.swift` | core-portable |
| `DensitySettingTests.swift` | macos-only |
| `DevinProviderTests.swift` | core-portable |
| `FailureBackoffTests.swift` | core-portable |
| `FirstRunSeederTests.swift` | core-portable |
| `GrokAuthStoreTests.swift` | core-portable |
| `GrokCreditsConfigFixtures.swift` | core-portable |
| `GrokCreditsConfigTests.swift` | core-portable |
| `GrokLogUsageScannerTests.swift` | core-portable |
| `GrokProviderTests.swift` | core-portable |
| `IncrementalJSONLScannerTests.swift` | core-portable |
| `KeychainAccessorTests.swift` | macos-only |
| `LaunchAtLoginSettingTests.swift` | macos-only |
| `LayoutBootstrapTests.swift` | core-portable |
| `LayoutPersistenceTests.swift` | core-portable |
| `LayoutStoreTests.swift` | macos-only |
| `LegacyLaunchAgentCleanupTests.swift` | macos-only |
| `LocalUsageAPITests.swift` | macos-only |
| `LogFileTests.swift` | needs-windows-fixture |
| `LogLevelSettingTests.swift` | core-portable |
| `LogRedactionTests.swift` | core-portable |
| `LoginShellEnvironmentTests.swift` | macos-only |
| `MenuBarBarsTests.swift` | macos-only |
| `MenuBarContentTests.swift` | macos-only |
| `MenuBarPinTests.swift` | macos-only |
| `MenuBarStripMemoTests.swift` | macos-only |
| `MenuBarStripTrimTests.swift` | macos-only |
| `MeterSeverityTests.swift` | core-portable |
| `MetricFormatterTests.swift` | core-portable |
| `MockData.swift` | macos-only |
| `ModelPricingStoreTests.swift` | core-portable |
| `ModelPricingTests.swift` | core-portable |
| `ModelUsageHoverTests.swift` | macos-only |
| `NewProviderSeederTests.swift` | core-portable |
| `OpenRouterProviderTests.swift` | core-portable |
| `OpenUsageISO8601Tests.swift` | core-portable |
| `PaceNotificationLogicTests.swift` | core-portable |
| `PaceTests.swift` | core-portable |
| `PanelGeometryTests.swift` | macos-only |
| `PanelHeightBridgeTests.swift` | core-portable |
| `PanelHeightCoordinatorTests.swift` | core-portable |
| `PanelOutsideClickPolicyTests.swift` | macos-only |
| `PopoverKeyReaderTests.swift` | macos-only |
| `PopoverScreenTests.swift` | macos-only |
| `PopoverSurfaceOpacityTests.swift` | macos-only |
| `PopoverTransparencyStoreTests.swift` | macos-only |
| `PopoverTransparencyStyleTests.swift` | core-portable |
| `PricingBundledResourceTests.swift` | core-portable |
| `ProcessRunnerTests.swift` | macos-only |
| `ProviderAuthRetryTests.swift` | core-portable |
| `ProviderEnablementEnforcementTests.swift` | core-portable |
| `ProviderEnablementStoreTests.swift` | core-portable |
| `ProviderLinksTests.swift` | core-portable |
| `ProviderMarksTests.swift` | core-portable |
| `ProviderSnapshotCacheTests.swift` | needs-windows-fixture |
| `ProxyConfigTests.swift` | needs-windows-fixture |
| `RefreshSettingTests.swift` | core-portable |
| `RefreshWakeSignalTests.swift` | core-portable |
| `ReorderGeometryTests.swift` | macos-only |
| `ResetDisplayTests.swift` | core-portable |
| `SecretCodeMatcherTests.swift` | core-portable |
| `SettingsMigratorTests.swift` | core-portable |
| `ShareCardRendererTests.swift` | macos-only |
| `SingleInstanceGuardTests.swift` | macos-only |
| `SingleInstanceLockTests.swift` | macos-only |
| `SpendTileMapperTests.swift` | core-portable |
| `StaleWhileRevalidateTests.swift` | needs-windows-fixture |
| `StalenessLabelTests.swift` | core-portable |
| `TelemetryRecorderTests.swift` | needs-windows-fixture |
| `TelemetrySinkTests.swift` | core-portable |
| `TestSupport.swift` | core-portable |
| `TotalSpendAggregatorTests.swift` | core-portable |
| `TransientNoticeTests.swift` | core-portable |
| `UpdaterControllerTests.swift` | macos-only |
| `UsageTrendTests.swift` | core-portable |
| `WidgetDataStoreNotificationTests.swift` | macos-only |
| `WidgetDataStorePlanTests.swift` | macos-only |
| `WidgetDataStoreTests.swift` | macos-only |
| `WidgetMeterStyleTests.swift` | core-portable |
| `WidgetNoDataTests.swift` | core-portable |
| `WidgetPercentClampTests.swift` | core-portable |
| `WidgetRegistryTests.swift` | core-portable |
| `WidgetUsagePeriodTests.swift` | core-portable |
| `WidgetZeroUsageTests.swift` | core-portable |
| `ZAILiveResponseMappingTests.swift` | core-portable |
| `ZAIProviderTests.swift` | core-portable |

**Test totals:** core-portable: 61, macos-only: 31, needs-windows-fixture: 6

## Summary totals (Sources/OpenUsage)

| Category | Count |
|---|---|
| PORTABLE-AS-IS | 96 |
| PORTABLE-AFTER-SEAM | 27 |
| MACOS-ADAPTER | 22 |
| WINDOWS-ADAPTER-NEEDED | 4 |
| UI-SHELL | 49 |
| **Total** | **198** |

### Target mapping (proposed Phase 1 split)

| Target | Inventory categories |
|---|---|
| `OpenUsageCore` | PORTABLE-AS-IS + PORTABLE-AFTER-SEAM (after seams land) |
| `OpenUsageMacAdapters` | MACOS-ADAPTER |
| `OpenUsageMacApp` | UI-SHELL + composition root (`AppContainer`) |
| `OpenUsageWindowsAdapters` | WINDOWS-ADAPTER-NEEDED (+ Windows credential vault, tray shell in Phase 3) |
