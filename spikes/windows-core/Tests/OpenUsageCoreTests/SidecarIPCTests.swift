import XCTest
@testable import OpenUsageCore

final class SidecarIPCTests: XCTestCase {
    func testPingRoundTrip() throws {
        let request = SidecarRequest(op: "ping")
        let line = try SidecarIPCCodec.encodeLine(request)
        let decoded = try SidecarIPCCodec.decodeRequestLine(line)
        XCTAssertEqual(decoded, request)
    }

    func testPongResponseRoundTrip() throws {
        let response = SidecarResponse.pong()
        let line = try SidecarIPCCodec.encodeLine(response)
        let decoded = try SidecarIPCCodec.decodeResponseLine(line)
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.version, SidecarProtocol.version)
    }

    func testSnapshotMapperProgressAndText() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Max",
            lines: [
                .progress(label: "Session", used: 42, limit: 100, format: .percent),
                .text(label: "Spend", value: "$1.23")
            ]
        )
        let dto = SidecarSnapshotMapper.makeProviderDTO(
            id: "claude",
            displayName: "Claude",
            credentialsFound: true,
            snapshot: snapshot
        )
        XCTAssertEqual(dto.status, "ok")
        XCTAssertEqual(dto.plan, "Max")
        XCTAssertEqual(dto.metricLines.count, 2)
        XCTAssertEqual(dto.metricLines[0].kind, "progress")
        XCTAssertTrue(dto.metricLines[0].display.contains("Session"))
        XCTAssertEqual(dto.metricLines[1].display, "Spend: $1.23")
    }

    func testSnapshotMapperNoCredentials() {
        let dto = SidecarSnapshotMapper.makeProviderDTO(
            id: "grok",
            displayName: "Grok",
            credentialsFound: false,
            snapshot: nil
        )
        XCTAssertEqual(dto.status, "no_credentials")
        XCTAssertTrue(dto.metricLines.isEmpty)
    }

    func testSnapshotMapperError() {
        let snapshot = ProviderSnapshot.error(provider: Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai")), message: "No API key")
        let dto = SidecarSnapshotMapper.makeProviderDTO(
            id: "zai",
            displayName: "Z.ai",
            credentialsFound: true,
            snapshot: snapshot
        )
        XCTAssertEqual(dto.status, "error")
        XCTAssertNotNil(dto.error)
    }
}
