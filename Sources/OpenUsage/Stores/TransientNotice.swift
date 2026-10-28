import Observation

@MainActor
@Observable
final class TransientNotice<Value> {
    private(set) var value: Value
    private(set) var trigger = 0

    private let clearedValue: Value
    private let timeout: Duration
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(clearedValue: Value, timeout: Duration) {
        self.value = clearedValue
        self.clearedValue = clearedValue
        self.timeout = timeout
    }

    func present(_ newValue: Value) {
        value = newValue
        trigger += 1
        clearTask?.cancel()
        let timeout = self.timeout
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            value = clearedValue
        }
    }

    func clear() {
        value = clearedValue
        clearTask?.cancel()
        clearTask = nil
    }
}
