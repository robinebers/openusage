import XCTest
@testable import OpenUsage

/// Mapper tests against payloads captured live from the home.qwencloud.com console API
/// (2026-07-29), trimmed of request IDs. The live bodies carry fields we don't map (`instanceCode`,
/// `addon_quota`, `ret`…), which exercises the unknown-field tolerance the mapper must keep.
final class QwenUsageMapperTests: XCTestCase {
    // MARK: - Fixtures

    static let infoBody = """
    {"requestId":"1a61679d","code":"200","data":{"sessionExpireTimeStamp":1787052662982,\
    "secToken":"NYOOSBQvO9PGTxFmHt0pT1","sessionCreateTimeStamp":1784460662982},\
    "httpStatusCode":null,"successResponse":true}
    """

    static let usageBody = """
    {"code":"200","data":{"DataV2":{"ret":["SUCCESS::OK"],"data":{"msg":"Success.","code":"SUCCESS",\
    "data":{"per5HourPercentage":0.10967993005003332,"per1WeekResetTime":1785802380000,\
    "per5HourResetTime":1785353040000,"per1WeekPercentage":0.31521579342249},\
    "requestId":"348ae586","success":true}},"success":true,"httpStatus":200,"errorCode":"",\
    "api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage","errorMsg":""},\
    "httpStatusCode":"200","requestId":"348ae586","successResponse":true}
    """

    static let subscriptionBody = """
    {"code":"200","data":{"DataV2":{"ret":["SUCCESS::OK"],"data":{"msg":"Success.","code":"SUCCESS",\
    "data":{"instanceCode":"sfm_tokenplansolo_public_intl-sg-o514vonhtcx","specCode":"standard",\
    "remainingDays":22,"startTime":1784590251000,"endTime":1787328000000,"autoRenewFlag":false,\
    "status":"VALID"},"requestId":"3eb648f6","success":true}},"success":true,"httpStatus":200,\
    "errorCode":"","api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription","errorMsg":""},\
    "httpStatusCode":"200","requestId":"3eb648f6","successResponse":true}
    """

    static let quotaConfigBody = """
    {"code":"200","data":{"DataV2":{"ret":["SUCCESS::OK"],"data":{"msg":"Success.","code":"SUCCESS",\
    "data":{"standard":{"five_hour":3000.0,"weekly":10000.0},"addon_quota":{"extrabundle":20000.0},\
    "lite":{"five_hour":700.0,"weekly":2500.0},"pro":{"five_hour":12000.0,"weekly":40000.0}},\
    "requestId":"88da1775","success":true}},"success":true,"httpStatus":200,"errorCode":"",\
    "api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config","errorMsg":""},\
    "httpStatusCode":"200","requestId":"88da1775","successResponse":true}
    """

    /// Wraps an inner payload in the gateway envelope so tests can vary just the payload.
    static func envelope(innerCode: String = "SUCCESS", payloadJSON: String, errorCode: String = "") -> String {
        """
        {"code":"200","data":{"DataV2":{"data":{"msg":"x","code":"\(innerCode)",\
        "data":\(payloadJSON),"success":true}},"success":true,"httpStatus":200,"errorCode":"\(errorCode)"}\
        ,"httpStatusCode":"200","successResponse":true}
        """
    }

    // MARK: - secToken / login-failure detection

    func testSecTokenExtraction() {
        XCTAssertEqual(QwenUsageMapper.secToken(from: Data(Self.infoBody.utf8)), "NYOOSBQvO9PGTxFmHt0pT1")
    }

    func testSecTokenMissingOnDeadSession() {
        let body = """
        {"code":"200","data":{"sessionExpireTimeStamp":null,"secToken":null},\
        "successResponse":false}
        """
        XCTAssertNil(QwenUsageMapper.secToken(from: Data(body.utf8)))
        XCTAssertTrue(QwenUsageMapper.isConsoleLoginFailure(Data(body.utf8)))
    }

    func testConsoleNeedLoginCodeIsLoginFailure() {
        let body = """
        {"code":"ConsoleNeedLogin","data":null,"successResponse":false}
        """
        XCTAssertTrue(QwenUsageMapper.isConsoleLoginFailure(Data(body.utf8)))
    }

    // MARK: - usage

    func testUsageMapsBothWindowsWithResetDates() throws {
        let lines = try QwenUsageMapper.mapUsage(Data(Self.usageBody.utf8))
        XCTAssertEqual(lines.count, 2)

        guard case .progress(let sessionLabel, let sessionUsed, let sessionLimit, let sessionFormat,
                             let sessionResets, let sessionPeriod, _) = lines[0] else {
            return XCTFail("expected a progress line for the 5-hour window")
        }
        XCTAssertEqual(sessionLabel, "5-Hour")
        XCTAssertEqual(sessionUsed, 0.10967993005003332 * 100, accuracy: 0.0001)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionFormat, .percent)
        XCTAssertEqual(sessionResets, Date(timeIntervalSince1970: 1785353040000.0 / 1000))
        XCTAssertEqual(sessionPeriod, MetricPeriod.sessionMs)

        guard case .progress(let weeklyLabel, let weeklyUsed, _, _, let weeklyResets, let weeklyPeriod, _) = lines[1] else {
            return XCTFail("expected a progress line for the weekly window")
        }
        XCTAssertEqual(weeklyLabel, "Weekly")
        XCTAssertEqual(weeklyUsed, 0.31521579342249 * 100, accuracy: 0.0001)
        XCTAssertEqual(weeklyResets, Date(timeIntervalSince1970: 1785802380000.0 / 1000))
        XCTAssertEqual(weeklyPeriod, MetricPeriod.weekMs)
    }

    func testUsageOverFullClampsToOneHundred() throws {
        let body = Self.envelope(payloadJSON: """
        {"per5HourPercentage":1.4,"per5HourResetTime":1785353040000,\
        "per1WeekPercentage":0.5,"per1WeekResetTime":1785802380000}
        """)
        let lines = try QwenUsageMapper.mapUsage(Data(body.utf8))
        guard case .progress(_, let used, _, _, _, _, _) = lines[0] else {
            return XCTFail("expected progress")
        }
        XCTAssertEqual(used, 100)
    }

    func testUsageMissingPercentageIsInvalidNotZero() {
        let body = Self.envelope(payloadJSON: """
        {"per5HourResetTime":1785353040000,"per1WeekPercentage":0.5,"per1WeekResetTime":1785802380000}
        """)
        XCTAssertThrowsError(try QwenUsageMapper.mapUsage(Data(body.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .invalidResponse)
        }
    }

    func testUsageNegativePercentageIsInvalid() {
        let body = Self.envelope(payloadJSON: """
        {"per5HourPercentage":-0.1,"per5HourResetTime":1785353040000,\
        "per1WeekPercentage":0.5,"per1WeekResetTime":1785802380000}
        """)
        XCTAssertThrowsError(try QwenUsageMapper.mapUsage(Data(body.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .invalidResponse)
        }
    }

    func testUsageMissingResetStillMaps() throws {
        let body = Self.envelope(payloadJSON: """
        {"per5HourPercentage":0.25,"per1WeekPercentage":0.5,"per1WeekResetTime":1785802380000}
        """)
        let lines = try QwenUsageMapper.mapUsage(Data(body.utf8))
        guard case .progress(_, _, _, _, let resets, _, _) = lines[0] else {
            return XCTFail("expected progress")
        }
        XCTAssertNil(resets)
    }

    func testGatewayLoginFailureSurfacesAsSessionExpired() {
        let body = Self.envelope(innerCode: "ConsoleNeedLogin", payloadJSON: "{}")
        XCTAssertThrowsError(try QwenUsageMapper.mapUsage(Data(body.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .sessionExpired)
        }
    }

    func testGatewayErrorCodeLoginFailureSurfacesAsSessionExpired() {
        let body = Self.envelope(payloadJSON: "{}", errorCode: "ConsoleNeedLogin")
        XCTAssertThrowsError(try QwenUsageMapper.mapUsage(Data(body.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .sessionExpired)
        }
    }

    func testNonSuccessInnerCodeIsInvalidResponse() {
        let body = Self.envelope(innerCode: "SOMETHING_ELSE", payloadJSON: "{}")
        XCTAssertThrowsError(try QwenUsageMapper.mapUsage(Data(body.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .invalidResponse)
        }
    }

    func testGarbageBodyIsInvalidResponse() {
        XCTAssertThrowsError(try QwenUsageMapper.mapUsage(Data("<html>nope</html>".utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .invalidResponse)
        }
    }

    // MARK: - subscription

    func testSubscriptionWithoutAutoRenewProducesWarning() throws {
        let info = try QwenUsageMapper.mapSubscription(Data(Self.subscriptionBody.utf8))
        XCTAssertEqual(info.tierKey, "standard")
        XCTAssertEqual(info.planName, "Standard")
        XCTAssertEqual(info.renewalWarning, "Auto-renew is off — plan ends in 22 days.")
    }

    func testSubscriptionWithAutoRenewHasNoWarning() throws {
        let body = Self.envelope(payloadJSON: """
        {"specCode":"pro","remainingDays":200,"autoRenewFlag":true,"status":"VALID"}
        """)
        let info = try QwenUsageMapper.mapSubscription(Data(body.utf8))
        XCTAssertEqual(info.planName, "Pro")
        XCTAssertNil(info.renewalWarning)
    }

    func testSubscriptionMissingSpecIsInvalid() {
        let body = Self.envelope(payloadJSON: """
        {"remainingDays":22,"autoRenewFlag":false}
        """)
        XCTAssertThrowsError(try QwenUsageMapper.mapSubscription(Data(body.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .invalidResponse)
        }
    }

    // MARK: - quota-config

    func testQuotaCapsForKnownTier() {
        let caps = QwenUsageMapper.quotaCaps(Data(Self.quotaConfigBody.utf8), tierKey: "standard")
        XCTAssertEqual(caps, QwenUsageMapper.QuotaCaps(fiveHour: 3000, weekly: 10000))
    }

    func testQuotaCapsForUnknownTierIsNil() {
        XCTAssertNil(QwenUsageMapper.quotaCaps(Data(Self.quotaConfigBody.utf8), tierKey: "mega"))
    }

    func testQuotaCapsNegativeValuesAreNil() {
        let body = Self.envelope(payloadJSON: """
        {"standard":{"five_hour":-1,"weekly":10000.0}}
        """)
        XCTAssertNil(QwenUsageMapper.quotaCaps(Data(body.utf8), tierKey: "standard"))
    }

    func testPlanLabelWithAndWithoutCaps() {
        let caps = QwenUsageMapper.QuotaCaps(fiveHour: 3000, weekly: 10000)
        XCTAssertEqual(QwenUsageMapper.planLabel(planName: "Standard", caps: caps),
                       "Standard · 3,000 / 5h · 10,000 / wk")
        XCTAssertEqual(QwenUsageMapper.planLabel(planName: "Standard", caps: nil), "Standard")
    }
}
