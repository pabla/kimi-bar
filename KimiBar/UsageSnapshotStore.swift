import Foundation

struct StoredUsageSnapshot: Equatable, Codable {
    let usage: UsageSnapshot
    let fetchedAt: Date
}

protocol UsageSnapshotStoring {
    func load() throws -> StoredUsageSnapshot?
    func save(_ snapshot: StoredUsageSnapshot) throws
}

struct UsageSnapshotStore: UsageSnapshotStoring {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> StoredUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(StoredUsageSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: StoredUsageSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
