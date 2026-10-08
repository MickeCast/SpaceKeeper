import Foundation

/// The latest layout seen for each display setup, persisted so a restart keeps them.
final class LayoutStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SpaceKeeper/layouts.json")

    private(set) var layouts: [String: Snapshot] = [:]
    private(set) var latest: Snapshot?
    private var persistedAt = Date.distantPast

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.url), let saved = try? decoder.decode([String: Snapshot].self, from: data) {
            layouts = saved
            latest = saved.values.max { $0.taken < $1.taken }
        }
    }

    func layout(for key: String) -> Snapshot? { layouts[key] }

    /// Records a layout; returns true when a window moved since the last one for this setup.
    @discardableResult
    func record(_ snapshot: Snapshot) -> Bool {
        var snapshot = snapshot
        let previous = layouts[snapshot.key]
        // Count time in use only between consecutive saves of the same setup (not across sleep).
        let gap = latest?.key == snapshot.key ? min(snapshot.taken.timeIntervalSince(latest?.taken ?? snapshot.taken), 60) : 0
        snapshot.observed = (previous?.observed ?? 0) + gap
        let changed = previous?.placement != snapshot.placement
        layouts[snapshot.key] = snapshot
        latest = snapshot
        if changed || Date().timeIntervalSince(persistedAt) > 300 { persist() }
        return changed
    }

    private func persist() {
        for key in layouts.sorted(by: { $0.value.taken > $1.value.taken }).dropFirst(12).map(\.key) { layouts[key] = nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        persistedAt = Date()
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(layouts).write(to: Self.url, options: .atomic)
        } catch {
            Log.write("couldn't save layouts: \(error)")
        }
    }
}
