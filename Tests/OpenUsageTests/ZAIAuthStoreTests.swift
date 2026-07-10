import XCTest
@testable import OpenUsage

final class ZAIAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() throws {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#]),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-file")
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() throws {
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-env")
    }

    func testAcceptsLegacyGLMEnvName() throws {
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["GLM_API_KEY": "glm-env"])
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "glm-env")
    }

    func testZAIKeyNameBeatsGLMKeyName() throws {
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai", "GLM_API_KEY": "glm"])
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai")
    }

    func testReadsKeyFromJSONConfigFile() throws {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{ "api_key": "zai-json" }"#]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-json")
    }

    func testReadsPlainTextKeyFile() throws {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[1]: "  zai-plain\n"]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-plain")
    }

    func testReturnsNilWhenNoKeyAnywhere() throws {
        let store = ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(try store.loadAPIKey())
    }

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  zai-new  ")

        XCTAssertEqual(files.files[ZAIAuthStore.configPaths[0]], #"{"apiKey":"zai-new"}"#)
        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-new")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let files = FakeFiles()
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? ZAIAuthError, .missingKey)
        }
        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = ZAIAuthStore(
            files: files,
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        try store.saveAPIKey("zai-saved")

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-saved")
        XCTAssertEqual(store.editorSnapshot().status, .overrideActive)
    }

    func testKeyStatusReportsAllHealthyStates() {
        let envKey = ["ZAI_API_KEY": "zai-env"]
        let file = [ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#]

        XCTAssertEqual(
            ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()).editorSnapshot().status,
            .notSet
        )
        XCTAssertEqual(
            ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).editorSnapshot().status,
            .fromEnvironment
        )
        XCTAssertEqual(
            ZAIAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).editorSnapshot().status,
            .saved
        )
        XCTAssertEqual(
            ZAIAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).editorSnapshot().status,
            .overrideActive
        )
    }

    func testEditorSnapshotReturnsEffectiveKey() {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#]),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        XCTAssertEqual(store.editorSnapshot().revealableKey, "zai-file")
    }

    func testDeleteAPIKeyFallsBackToEnvironment() throws {
        let files = FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#])
        let store = ZAIAuthStore(
            files: files,
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        XCTAssertEqual(store.editorSnapshot().status, .overrideActive)
        try store.deleteAPIKey()

        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
        XCTAssertEqual(store.editorSnapshot().status, .fromEnvironment)
        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-env")
    }

    func testDeleteAPIKeyBecomesNotSetWhenNoEnvKey() throws {
        let files = FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
        XCTAssertEqual(store.editorSnapshot().status, .notSet)
        XCTAssertNil(try store.loadAPIKey())
    }

    func testDeleteAPIKeyIsNoOpWhenFileMissing() throws {
        let store = ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())

        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertEqual(store.editorSnapshot().status, .notSet)
    }

    func testDeleteAPIKeyClearsAllConfigPaths() throws {
        let files = FakeFiles([
            ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-primary"}"#,
            ZAIAuthStore.configPaths[1]: "zai-alt"
        ])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
        XCTAssertNil(files.files[ZAIAuthStore.configPaths[1]])
        XCTAssertEqual(store.editorSnapshot().status, .notSet)
    }
}
