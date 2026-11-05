import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class AccountNameTextTests: QuietWindowTestCase {
    func testPrivateNamesHaveTheSamePixelsAndSizeRegardlessOfTheirOriginalLength() async throws {
        enableAccessibility()
        let names = ["Z", "private@example.com", "A Very Long Private Customer Project Name"]
        let widths: [CGFloat?] = [nil, 55]

        for width in widths {
            var concealedImages: [Data] = []
            var concealedSizes: [CGSize] = []
            var visibleImages: [Data] = []

            for name in names {
                let provider = Provider(id: "claude@private", kind: .claude, accountLabel: name)
                for privacyMode in [true, false] {
                    let view = AccountNameText(provider: provider, privacyMode: privacyMode)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(provider.isNamedByEmail ? .middle : .tail)
                        .frame(width: width, alignment: .leading)
                        .padding(12)
                        .background(Color.white)
                        .environment(\.colorScheme, .light)
                    let host = show(view, size: CGSize(width: 360, height: 50)).host
                    try await waitUntil {
                        self.accessibilityText(in: host).contains(privacyMode ? "Hidden Account" : name)
                    }
                    // NSView.cacheDisplay omits SwiftUI blur filters; compare the actual share-card renderer.
                    let image = try XCTUnwrap(ShareCardRenderer.png(for: view))
                    if privacyMode {
                        concealedImages.append(image)
                        concealedSizes.append(host.fittingSize)
                        let accessibility = accessibilityText(in: host)
                        XCTAssertTrue(accessibility.contains("Hidden Account"))
                        XCTAssertFalse(accessibility.contains(name), "the original name must not remain in the accessibility tree")
                        XCTAssertFalse(accessibility.contains("@"), "the blurred dummy address must not be read by a screen reader")
                    } else {
                        visibleImages.append(image)
                    }
                }
            }

            let reference = try rgbaPixels(in: XCTUnwrap(concealedImages.first))
            for image in concealedImages.dropFirst() {
                let rendered = try rgbaPixels(in: image)
                XCTAssertEqual(rendered.size, reference.size)
                let differences = zip(reference.pixels, rendered.pixels).map { abs(Int($0) - Int($1)) }
                // Re-rendering even the identical blurred view can vary by two 8-bit channel levels.
                // Compare decoded pixels, allowing only that rounding noise rather than PNG byte identity.
                XCTAssertLessThanOrEqual(differences.max() ?? 0, 2, "private characters, length or truncation changed the placeholder")
                XCTAssertLessThan(Double(differences.reduce(0, +)) / Double(differences.count), 0.1)
            }
            XCTAssertTrue(concealedSizes.dropFirst().allSatisfy { $0 == concealedSizes.first })
            XCTAssertEqual(Set(visibleImages).count, names.count, "turning Privacy Mode off must draw each original name")
            XCTAssertTrue(visibleImages.allSatisfy { $0 != concealedImages.first }, "the private display must differ from every real name")
        }
    }

    func testLiveToggleRestoresTheOriginalNameAndKeepsThePlaceholderOnHoverAndClick() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let saved = accounts.add(kind: .claude, label: "private@example.com", credential: .apiKey("unused"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        let provider = Provider(id: saved.cardID, kind: .claude, accountLabel: saved.label)
        let (window, host) = show(
            AccountName(account: DashboardAccount(provider: provider, lines: []), font: .body)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .defaultAppStorage(defaults)
                .environment(container.renaming),
            size: CGSize(width: 360, height: 60)
        )
        try await waitUntil { self.accessibilityText(in: host).contains(saved.label) }
        let original = try pixels(of: host)

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil { self.accessibilityText(in: host).contains("Hidden Account") }
        let concealed = try pixels(of: host)
        XCTAssertNotEqual(concealed, original)

        let point = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        send(.mouseMoved, at: point, window, host)
        click(point, window, host)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: point.x, y: host.bounds.height - point.y),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 2,
                pressure: type == .leftMouseDown ? 1 : 0
            )))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(container.renaming.edit, "clicking the placeholder must not open a rename field with the private name")
        XCTAssertEqual(try pixels(of: host), concealed, "pointer interaction must not reveal the account")
        XCTAssertFalse(accessibilityText(in: host).contains(saved.label))
        XCTAssertFalse(accessibilityText(in: host).localizedCaseInsensitiveContains("reveal"))

        defaults.set(false, forKey: PrivacyModeSetting.key)
        try await waitUntil { self.accessibilityText(in: host).contains(saved.label) }
        XCTAssertEqual(try pixels(of: host), original)
        XCTAssertEqual(accounts.account(cardID: saved.cardID)?.label, saved.label)
    }

    func testPrivateEnterpriseDomainsDoNotChangeTheCopiedCardPixels() throws {
        let domains = ["a.ghe.com", "private-company.ghe.com"]
        func image(domain: String, privacyMode: Bool) throws -> Data {
            let defaults = isolatedDefaults()
            defaults.set(privacyMode, forKey: PrivacyModeSetting.key)
            let provider = Provider(id: "copilot@private", kind: .copilot, accountLabel: "Work", domain: domain)
            let data = WidgetData(title: "Premium Requests", kind: .percent, used: 30, limit: 100)
            let descriptor = WidgetDescriptor(provider: provider, key: "premium", metricLabel: data.title, sample: data)
            let account = DashboardAccount(provider: provider, lines: [DashboardLine(descriptor: descriptor, data: data)])
            let family = DashboardFamily(id: "copilot", provider: provider, accounts: [account])
            let view = ShareCardView(family: family, plans: [provider.id: "Enterprise"], appearance: .light)
                .defaultAppStorage(defaults)
            return try XCTUnwrap(ShareCardRenderer.png(for: view))
        }

        let first = try rgbaPixels(in: image(domain: domains[0], privacyMode: true))
        let second = try rgbaPixels(in: image(domain: domains[1], privacyMode: true))
        XCTAssertEqual(first.size, second.size)
        let differences = zip(first.pixels, second.pixels).map { abs(Int($0) - Int($1)) }
        // Allow the same small blur-rendering rounding noise as the account-name comparison above.
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 2, "the copied picture must contain no domain-dependent pixels")
        XCTAssertLessThan(Double(differences.reduce(0, +)) / Double(differences.count), 0.1)

        let visibleFirst = try rgbaPixels(in: image(domain: domains[0], privacyMode: false))
        let visibleSecond = try rgbaPixels(in: image(domain: domains[1], privacyMode: false))
        XCTAssertNotEqual(visibleFirst.pixels, visibleSecond.pixels, "turning Privacy Mode off must render each original domain")
    }

    private func enableAccessibility() {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        addTeardownBlock { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
    }

    private func rgbaPixels(in png: Data) throws -> (size: CGSize, pixels: [UInt8]) {
        let image = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (CGSize(width: image.width, height: image.height), pixels)
    }

    private func accessibilityText(in element: Any) -> String {
        var visited: Set<ObjectIdentifier> = []
        func strings(in element: Any) -> [String] {
            guard let node = element as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let attributes = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityHelp"]
            let values = attributes.compactMap { key -> String? in
                guard node.responds(to: NSSelectorFromString(key)) else { return nil }
                return node.value(forKey: key) as? String
            }
            guard node.responds(to: NSSelectorFromString("accessibilityChildren")) else { return values }
            return values + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(strings)
        }
        return strings(in: element).joined(separator: " ")
    }
}
