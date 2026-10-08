import Foundation

enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SpaceKeeper")
    static let url = directory.appendingPathComponent("SpaceKeeper.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        guard let line = "\(formatter.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let previous = directory.appendingPathComponent("SpaceKeeper.1.log")
            try? files.removeItem(at: previous)
            try? files.moveItem(at: url, to: previous)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
