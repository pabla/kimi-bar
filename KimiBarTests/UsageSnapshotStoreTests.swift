import XCTest
@testable import KimiBar

final class UsageSnapshotStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try super.tearDownWithError()
    }

    func testFileStoreRestoresUsageAndSuccessTimestampWithoutSecrets() throws {
        let fileURL = rootURL
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("usage.json")
        let snapshot = StoredUsageSnapshot(
            usage: UsageSnapshot(
                fiveHour: UsageLimit(
                    remainingRatio: 0.25,
                    resetTime: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                monthly: UsageLimit(remainingRatio: 0.75, resetTime: nil)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try UsageSnapshotStore(fileURL: fileURL).save(snapshot)
        let restored = try UsageSnapshotStore(fileURL: fileURL).load()

        XCTAssertEqual(restored, snapshot)
        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("accessToken"))
        XCTAssertFalse(json.contains("refreshToken"))
        XCTAssertFalse(json.contains("access_token"))
        XCTAssertFalse(json.contains("refresh_token"))
        XCTAssertFalse(json.contains("Authorization"))
    }

    func testMissingFileLoadsNoSnapshot() throws {
        let store = UsageSnapshotStore(
            fileURL: rootURL.appendingPathComponent("missing.json")
        )
        XCTAssertNil(try store.load())
    }
}
