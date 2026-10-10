import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = home.appendingPathComponent(".config/rzmacro")
    static let configFile = configDir.appendingPathComponent("config.json5")
    static let socket = configDir.appendingPathComponent("rzmacro.sock")
    static let logFile = home.appendingPathComponent("Library/Logs/rzmacro.log")
    /// Product photos the user chose to download.
    static let pictures = home.appendingPathComponent("Library/Application Support/rzmacro/devices")
}

final class Log {
    static let shared = Log()

    private var handle: FileHandle?
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func open() {
        let fm = FileManager.default
        let path = Paths.logFile.path
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        handle?.write(line.data(using: .utf8)!)
        if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(line.data(using: .utf8)!) }
    }
}

func log(_ message: String) { Log.shared.write(message) }

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}
