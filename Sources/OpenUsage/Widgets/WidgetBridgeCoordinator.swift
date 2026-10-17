import Foundation
import Observation
import OpenUsageWidgetSupport
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
protocol WidgetBridgePersisting {
    func read() throws -> WidgetBridgeDocument?
    func write(_ document: WidgetBridgeDocument) throws
}

extension WidgetBridgeFileStore: WidgetBridgePersisting {}

/// Tracks only state read by `WidgetBridgeExporter`, coalesces bursts, and reloads WidgetKit after a
/// changed document has been committed. Errors are loud and never replace the previous good payload.
@MainActor
final class WidgetBridgeCoordinator {
    static let widgetKind = "ProviderUsageWidget"

    private let exporter: WidgetBridgeExporter
    private let store: any WidgetBridgePersisting
    private let now: () -> Date
    private let reload: () -> Void
    private let debounceDuration: Duration
    private var lastContent: WidgetBridgeDocument.SemanticContent?
    private var debounceTask: Task<Void, Never>?
    private var isObserving = false

    init(
        exporter: WidgetBridgeExporter,
        store: any WidgetBridgePersisting,
        debounceDuration: Duration = .milliseconds(250),
        now: @escaping () -> Date = Date.init,
        reload: @escaping () -> Void
    ) {
        self.exporter = exporter
        self.store = store
        self.debounceDuration = debounceDuration
        self.now = now
        self.reload = reload
    }

    deinit {
        debounceTask?.cancel()
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        exportIfChanged()
        observeNextChange()
    }

    func exportIfChanged() {
        let document = exporter.makeDocument(generatedAt: now())
        if lastContent == nil {
            do {
                lastContent = try store.read()?.semanticContent
            } catch {
                // A corrupt/unsupported old file must be replaced by a valid current document.
                AppLog.error(.config, "widget bridge read failed: \(error.localizedDescription)")
            }
        }
        guard document.semanticContent != lastContent else { return }
        do {
            try store.write(document)
            lastContent = document.semanticContent
            reload()
            AppLog.debug(.config, "widget bridge exported \(document.providers.count) providers")
        } catch {
            AppLog.error(.config, "widget bridge write failed: \(error.localizedDescription)")
        }
    }

    private func observeNextChange() {
        withObservationTracking {
            _ = exporter.makeDocument(generatedAt: now()).semanticContent
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.observeNextChange()
                self.scheduleExport()
            }
        }
    }

    private func scheduleExport() {
        debounceTask?.cancel()
        let duration = debounceDuration
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.exportIfChanged()
        }
    }

    static func makeDefault(
        exporter: WidgetBridgeExporter,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> WidgetBridgeCoordinator? {
        guard let appGroup = bundle.object(forInfoDictionaryKey: "OpenUsageAppGroupIdentifier") as? String,
              !appGroup.isEmpty else {
            AppLog.warn(.config, "widget bridge disabled: OpenUsageAppGroupIdentifier is missing")
            return nil
        }
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            AppLog.error(.config, "widget bridge disabled: App Group container is unavailable")
            return nil
        }
        let store = WidgetBridgeFileStore(appGroupContainerURL: containerURL)
        return WidgetBridgeCoordinator(exporter: exporter, store: store) {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
            #endif
        }
    }
}
