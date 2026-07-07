import Foundation
import XCTest
@testable import OpenUsage

// MARK: - QoderAuthStoreTests

final class QoderAuthStoreTests: XCTestCase {
    func testLoggedInCLIUsesQodercliAuth() throws {
        let runner = FakeQoderStatusRunner(result: .success(statusResult(loggedIn: true)))
        let store = QoderAuthStore(
            environment: FakeEnvironment([QoderAuthStore.cliPathEnvironmentName: "/tmp/qodercli"]),
            processRunner: runner,
            fileManager: FakeQoderFileManager(executablePaths: ["/tmp/qodercli"])
        )

        guard case .authenticated(let auth) = store.loadAuth() else {
            return XCTFail("expected authenticated local CLI")
        }

        XCTAssertEqual(auth.executable, "/tmp/qodercli")
        XCTAssertEqual(auth.method, .qodercli)
        XCTAssertEqual(runner.calls.map(\.arguments), [["status", "--output", "json"]])
    }

    func testPATFallbackWhenCLIIsInstalledButNotLoggedIn() throws {
        let runner = FakeQoderStatusRunner(result: .success(statusResult(loggedIn: false)))
        let store = QoderAuthStore(
            environment: FakeEnvironment([
                QoderAuthStore.cliPathEnvironmentName: "/tmp/qodercli",
                QoderAuthStore.personalAccessTokenEnvironmentName: " qoder-pat "
            ]),
            processRunner: runner,
            fileManager: FakeQoderFileManager(executablePaths: ["/tmp/qodercli"])
        )

        guard case .authenticated(let auth) = store.loadAuth() else {
            return XCTFail("expected PAT auth")
        }

        XCTAssertEqual(auth.executable, "/tmp/qodercli")
        XCTAssertEqual(auth.method, .accessToken("qoder-pat"))
    }

    func testMissingConfiguredCLIDoesNotUsePATAlone() {
        let runner = FakeQoderStatusRunner(result: .success(statusResult(loggedIn: true)))
        let store = QoderAuthStore(
            environment: FakeEnvironment([
                QoderAuthStore.cliPathEnvironmentName: "/tmp/missing-qodercli",
                QoderAuthStore.personalAccessTokenEnvironmentName: "qoder-pat"
            ]),
            processRunner: runner,
            fileManager: FakeQoderFileManager()
        )

        XCTAssertEqual(store.loadAuth(), .missingCLI)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFindsExecutableFromLoginShellPath() throws {
        let runner = FakeQoderStatusRunner(result: .success(statusResult(loggedIn: true)))
        let store = QoderAuthStore(
            environment: FakeEnvironment(["PATH": "/custom/bin:/usr/bin"]),
            processRunner: runner,
            fileManager: FakeQoderFileManager(executablePaths: ["/custom/bin/qodercli"])
        )

        guard case .authenticated(let auth) = store.loadAuth() else {
            return XCTFail("expected path auth")
        }

        XCTAssertEqual(auth.executable, "/custom/bin/qodercli")
    }

    func testFindsExecutableFromLoginShellPathWhenProcessPathIsPresent() throws {
        let runner = FakeQoderStatusRunner(result: .success(statusResult(loggedIn: true)))
        let store = QoderAuthStore(
            environment: FakeEnvironment(["PATH": "/usr/bin:/bin"]),
            processRunner: runner,
            fileManager: FakeQoderFileManager(executablePaths: ["/shell/bin/qodercli"]),
            loginShellPath: { "/shell/bin:/usr/local/bin" }
        )

        guard case .authenticated(let auth) = store.loadAuth() else {
            return XCTFail("expected shell path auth")
        }

        XCTAssertEqual(auth.executable, "/shell/bin/qodercli")
    }

    func testStatusTimeoutFallsBackToPATWhenAvailable() throws {
        let runner = FakeQoderStatusRunner(result: .failure(ProcessRunnerError.timedOut(executable: "/tmp/qodercli", timeout: 5)))
        let store = QoderAuthStore(
            environment: FakeEnvironment([
                QoderAuthStore.cliPathEnvironmentName: "/tmp/qodercli",
                QoderAuthStore.personalAccessTokenEnvironmentName: "qoder-pat"
            ]),
            processRunner: runner,
            fileManager: FakeQoderFileManager(executablePaths: ["/tmp/qodercli"])
        )

        guard case .authenticated(let auth) = store.loadAuth() else {
            return XCTFail("expected PAT fallback")
        }

        XCTAssertEqual(auth.method, .accessToken("qoder-pat"))
    }

    func testStatusFailureWithoutPATReportsUnavailable() {
        let runner = FakeQoderStatusRunner(result: .failure(ProcessRunnerError.timedOut(executable: "/tmp/qodercli", timeout: 5)))
        let store = QoderAuthStore(
            environment: FakeEnvironment([QoderAuthStore.cliPathEnvironmentName: "/tmp/qodercli"]),
            processRunner: runner,
            fileManager: FakeQoderFileManager(executablePaths: ["/tmp/qodercli"])
        )

        XCTAssertEqual(store.loadAuth(), .statusUnavailable)
    }
}

// MARK: - QoderUsageClientTests

final class QoderUsageClientTests: XCTestCase {
    func testFetchUsageSendsSDKControlRequestsAndDeletesAuthPayload() throws {
        let observedPayloadPath = LockedBox<String?>(nil)
        let runner = FakeQoderStreamRunner { call in
            XCTAssertEqual(call.executable, "/tmp/qodercli")
            XCTAssertEqual(call.arguments, [
                "--print",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--tools", ""
            ])
            XCTAssertEqual(call.environment["QODER_AGENT_SDK_ENTRYPOINT"], QoderUsageClient.sdkEntrypoint)
            XCTAssertEqual(call.environment["QODER_AGENT_SDK_VERSION"], QoderUsageClient.sdkVersion)
            XCTAssertTrue(call.stdin.contains(#""type":"initialize""#))
            XCTAssertTrue(call.stdin.contains(#""type":"get_usage_info""#))

            let payloadPath = try XCTUnwrap(call.environment["QODER_SDK_AUTH_PAYLOAD_FILE"])
            observedPayloadPath.value = payloadPath
            let payload = try jsonObject(at: payloadPath)
            XCTAssertEqual(payload["type"] as? String, "qodercli")

            let usageRequestID = try requestID(for: "get_usage_info", in: call.stdin)
            return QoderStreamProcessResult(
                exitCode: 0,
                stdout: usageResponseLine(requestID: usageRequestID, usage: fullUsageObject()),
                stderr: ""
            )
        }
        let client = QoderUsageClient(processRunner: runner)

        let usage = try client.fetchUsage(auth: QoderAuth(executable: "/tmp/qodercli", method: .qodercli))

        XCTAssertEqual(usage.userQuota?.used, 12.5)
        XCTAssertEqual(usage.totalUsagePercentage, 37.5)
        XCTAssertEqual(runner.calls.count, 1)
        let payloadPath = try XCTUnwrap(observedPayloadPath.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadPath))
    }

    func testFetchUsageWritesAccessTokenPayload() throws {
        let runner = FakeQoderStreamRunner { call in
            let payloadPath = try XCTUnwrap(call.environment["QODER_SDK_AUTH_PAYLOAD_FILE"])
            let payload = try jsonObject(at: payloadPath)
            XCTAssertEqual(payload["type"] as? String, "accessToken")
            XCTAssertEqual(payload["accessToken"] as? String, "qoder-pat")

            let usageRequestID = try requestID(for: "get_usage_info", in: call.stdin)
            return QoderStreamProcessResult(
                exitCode: 0,
                stdout: usageResponseLine(requestID: usageRequestID, usage: fullUsageObject()),
                stderr: ""
            )
        }
        let client = QoderUsageClient(processRunner: runner)

        let usage = try client.fetchUsage(auth: QoderAuth(executable: "/tmp/qodercli", method: .accessToken("qoder-pat")))

        XCTAssertEqual(usage.orgResourcePackage?.cap, 500)
    }

    func testFetchUsageReportsUnsupportedCLIWhenUsageIsMissingForLocalLogin() {
        let runner = FakeQoderStreamRunner { call in
            let usageRequestID = try requestID(for: "get_usage_info", in: call.stdin)
            return QoderStreamProcessResult(
                exitCode: 0,
                stdout: usageResponseLine(requestID: usageRequestID, usage: nil),
                stderr: ""
            )
        }
        let client = QoderUsageClient(processRunner: runner)

        XCTAssertThrowsError(try client.fetchUsage(auth: QoderAuth(executable: "/tmp/qodercli", method: .qodercli))) { error in
            XCTAssertEqual(error as? QoderUsageError, .unsupportedCLI)
        }
    }

    func testFetchUsageReportsMalformedStreamAsInvalidResponse() {
        let runner = FakeQoderStreamRunner { _ in
            QoderStreamProcessResult(exitCode: 0, stdout: "{not-json\n", stderr: "")
        }
        let client = QoderUsageClient(processRunner: runner)

        XCTAssertThrowsError(try client.fetchUsage(auth: QoderAuth(executable: "/tmp/qodercli", method: .qodercli))) { error in
            XCTAssertEqual(error as? QoderUsageError, .invalidResponse)
        }
    }

    func testCLIProcessRunnerTimeoutDoesNotHangWhenChildKeepsPipeOpen() {
        let started = Date()
        let runner = QoderCLIProcessRunner()

        XCTAssertThrowsError(try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "(sleep 5) & sleep 5"],
            environment: [:],
            stdin: "",
            timeout: 0.1
        )) { error in
            guard case ProcessRunnerError.timedOut(_, _) = error else {
                return XCTFail("expected timeout")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

// MARK: - QoderUsageMapperTests

final class QoderUsageMapperTests: XCTestCase {
    func testMapsAllUsageBuckets() throws {
        let usage = try decodeUsage(fullUsageObject())

        let lines = QoderUsageMapper.map(usage)

        let plan = try XCTUnwrap(progress(lines, QoderMetric.monthly))
        XCTAssertEqual(plan.used, 12.5, accuracy: 0.001)
        XCTAssertEqual(plan.limit, 100, accuracy: 0.001)
        XCTAssertEqual(plan.format, .percent)
        XCTAssertEqual(try XCTUnwrap(plan.resetsAt?.timeIntervalSince1970), 1_770_648_402.389, accuracy: 0.001)

        let addOn = try XCTUnwrap(progress(lines, QoderMetric.addOnCredits))
        XCTAssertEqual(addOn.used, 8, accuracy: 0.001)
        XCTAssertEqual(addOn.limit, 40, accuracy: 0.001)

        let org = try XCTUnwrap(progress(lines, QoderMetric.orgCredits))
        XCTAssertEqual(org.used, 123, accuracy: 0.001)
        XCTAssertEqual(org.limit, 500, accuracy: 0.001)
    }

    func testOmitsMissingOptionalBucketsWithoutFabricatingZero() throws {
        let usage = try decodeUsage([
            "totalUsagePercentage": 3,
            "userQuota": [
                "used": 3,
                "total": 100,
                "remaining": 97,
                "unit": "credits"
            ]
        ])

        let lines = QoderUsageMapper.map(usage)

        XCTAssertNotNil(progress(lines, QoderMetric.monthly))
        XCTAssertNil(progress(lines, QoderMetric.addOnCredits))
        XCTAssertNil(progress(lines, QoderMetric.orgCredits))
        XCTAssertFalse(lines.contains { $0 == .noUsageData })
    }

    func testMonthlyFallsBackToComputedPercentage() throws {
        let usage = try decodeUsage([
            "userQuota": [
                "used": 50,
                "total": 200,
                "remaining": 150,
                "unit": "credits"
            ]
        ])

        let lines = QoderUsageMapper.map(usage)

        let monthly = try XCTUnwrap(progress(lines, QoderMetric.monthly))
        XCTAssertEqual(monthly.used, 25, accuracy: 0.001)
        XCTAssertEqual(monthly.limit, 100, accuracy: 0.001)
        XCTAssertEqual(monthly.format, .percent)
    }

    func testEmptyUsageYieldsNoUsageData() throws {
        let lines = QoderUsageMapper.map(try decodeUsage([:]))
        XCTAssertEqual(lines, [.noUsageData])
    }
}

// MARK: - QoderProviderTests

@MainActor
final class QoderProviderTests: XCTestCase {
    func testProviderIdentityDescriptorsAndDefaultLayout() throws {
        let provider = QoderProvider()

        XCTAssertEqual(provider.provider.id, "qoder")
        XCTAssertEqual(provider.provider.displayName, "Qoder")
        XCTAssertEqual(provider.provider.visibleLinks.map(\.label), ["Dashboard"])
        XCTAssertEqual(provider.provider.visibleLinks.map(\.url), ["https://qoder.com/account/usage"])
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), [
            "qoder.planCredits",
            "qoder.addOnCredits",
            "qoder.orgCredits"
        ])
        XCTAssertEqual(provider.widgetDescriptors.map(\.title), [
            "Monthly",
            "Add-on Credits",
            "Org Credits"
        ])
        XCTAssertEqual(provider.widgetDescriptors.first?.sample.kind, .percent)

        let suiteName = "OpenUsage.QoderLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: WidgetRegistry.from([provider]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "qoder.planCredits",
            "qoder.addOnCredits",
            "qoder.orgCredits"
        ])
        XCTAssertEqual(store.pinnedMetricIDs, ["qoder.planCredits"] as Set<String>)

        let group = try XCTUnwrap(store.customizeGroups.first)
        XCTAssertEqual(group.alwaysShownMetrics.map(\.id), ["qoder.planCredits"])
        XCTAssertEqual(group.expandedMetrics.map(\.id), ["qoder.addOnCredits", "qoder.orgCredits"])
    }

    func testHasLocalCredentialsUsesQoderCLIStatus() async {
        let provider = QoderProvider(
            authStore: makeAuthStore(loggedIn: true),
            usageClient: QoderUsageClient(processRunner: FakeQoderStreamRunner.success())
        )

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
    }

    func testRefreshMapsLocalCLIUsage() async throws {
        let provider = QoderProvider(
            authStore: makeAuthStore(loggedIn: true),
            usageClient: QoderUsageClient(processRunner: FakeQoderStreamRunner.success()),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.providerID, "qoder")
        XCTAssertEqual(snapshot.displayName, "Qoder")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.refreshedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNotNil(snapshot.line(label: QoderMetric.monthly))
        XCTAssertNil(snapshot.line(label: "Total Usage"))
    }

    func testRefreshMissingCLIReportsFriendlyError() async {
        let provider = QoderProvider(
            authStore: QoderAuthStore(
                environment: FakeEnvironment([QoderAuthStore.cliPathEnvironmentName: "/tmp/missing-qodercli"]),
                processRunner: FakeQoderStatusRunner(result: .success(statusResult(loggedIn: true))),
                fileManager: FakeQoderFileManager()
            ),
            usageClient: QoderUsageClient(processRunner: FakeQoderStreamRunner.success())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        guard case .badge(_, let text, _, _) = snapshot.lines.first else {
            return XCTFail("expected an error badge")
        }
        XCTAssertTrue(text.contains("Qoder CLI not installed"))
    }

    private func makeAuthStore(loggedIn: Bool) -> QoderAuthStore {
        QoderAuthStore(
            environment: FakeEnvironment([QoderAuthStore.cliPathEnvironmentName: "/tmp/qodercli"]),
            processRunner: FakeQoderStatusRunner(result: .success(statusResult(loggedIn: loggedIn))),
            fileManager: FakeQoderFileManager(executablePaths: ["/tmp/qodercli"])
        )
    }
}

// MARK: - Test Doubles

private struct FakeQoderFileManager: FileManagerAccessing {
    var executablePaths: Set<String> = []
    var directories: [String: [String]] = [:]

    func isExecutableFile(_ path: String) -> Bool {
        executablePaths.contains(path)
    }

    func contentsOfDirectory(_ path: String) throws -> [String] {
        directories[path] ?? []
    }
}

private final class FakeQoderStatusRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var callsStorage: [Call] = []
    private let result: Result<ProcessResult, Error>

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    init(result: Result<ProcessResult, Error>) {
        self.result = result
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.lock()
        callsStorage.append(Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        lock.unlock()

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class FakeQoderStreamRunner: QoderStreamProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var stdin: String
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var callsStorage: [Call] = []
    private let handler: (Call) throws -> QoderStreamProcessResult

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    init(handler: @escaping (Call) throws -> QoderStreamProcessResult) {
        self.handler = handler
    }

    static func success() -> FakeQoderStreamRunner {
        FakeQoderStreamRunner { call in
            let usageRequestID = try requestID(for: "get_usage_info", in: call.stdin)
            return QoderStreamProcessResult(
                exitCode: 0,
                stdout: usageResponseLine(requestID: usageRequestID, usage: fullUsageObject()),
                stderr: ""
            )
        }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: String,
        timeout: TimeInterval
    ) throws -> QoderStreamProcessResult {
        let call = Call(
            executable: executable,
            arguments: arguments,
            environment: environment,
            stdin: stdin,
            timeout: timeout
        )
        lock.lock()
        callsStorage.append(call)
        lock.unlock()
        return try handler(call)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

// MARK: - Test Helpers

private enum QoderTestError: Error {
    case missingControlRequest
}

private func statusResult(loggedIn: Bool) -> ProcessResult {
    ProcessResult(exitCode: 0, stdout: #"{"logged_in":\#(loggedIn)}"#, stderr: "")
}

private func fullUsageObject() -> [String: Any] {
    [
        "totalUsagePercentage": 37.5,
        "expiresAt": 1_770_648_402_389.0,
        "userQuota": [
            "used": 12.5,
            "total": 100.0,
            "remaining": 87.5,
            "percentage": 12.5,
            "unit": "credits"
        ],
        "addOnQuota": [
            "used": 8.0,
            "total": 40.0,
            "remaining": 32.0,
            "percentage": 20.0,
            "unit": "credits",
            "detailUrl": "https://qoder.com"
        ],
        "orgResourcePackage": [
            "used": 123.0,
            "cap": 500.0,
            "remaining": 377.0,
            "percentage": 24.6,
            "available": true,
            "unit": "credits"
        ]
    ]
}

private func decodeUsage(_ object: [String: Any]) throws -> QoderUsageInfo {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(QoderUsageInfo.self, from: data)
}

private func jsonObject(at path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func requestID(for requestType: String, in stdin: String) throws -> String {
    for line in stdin.split(whereSeparator: \.isNewline) {
        guard let data = String(line).data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "control_request",
              let request = root["request"] as? [String: Any],
              request["type"] as? String == requestType,
              let requestID = root["request_id"] as? String else {
            continue
        }
        return requestID
    }
    throw QoderTestError.missingControlRequest
}

private func usageResponseLine(requestID: String, usage: [String: Any]?) -> String {
    let payload: [String: Any]
    if let usage {
        payload = ["usage": usage]
    } else {
        payload = [:]
    }
    return jsonLine([
        "type": "control_response",
        "response": [
            "subtype": "success",
            "request_id": requestID,
            "response": payload
        ]
    ])
}

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func progress(
    _ lines: [MetricLine],
    _ label: String
) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?)? {
    guard case .progress(_, let used, let limit, let format, let resetsAt, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, format, resetsAt)
}
