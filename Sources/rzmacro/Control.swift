import Foundation

/// The daemon's control channel: a unix socket speaking one text command per connection.
/// The reply is free-form text; the server closes the connection when it is done.

private func makeAddress() -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(Paths.socket.path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.prefix(buffer.count - 1))
    }
    return address
}

private func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

final class ControlConnection {
    private let fd: Int32
    private(set) var isClosed = false

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard !isClosed else { return false }
        let bytes = Array((text.hasSuffix("\n") ? text : text + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written <= 0 { close(); return false }
            offset += written
        }
        return true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

final class ControlServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var onCommand: ((String, ControlConnection) -> Void)?

    func start() throws {
        unlink(Paths.socket.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = makeAddress()
        guard fd >= 0, withSockaddr(&address, { bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else {
            throw ConfigError("cannot listen on \(Paths.socket.path): \(String(cString: strerror(errno)))")
        }
        chmod(Paths.socket.path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(Paths.socket.path)
    }

    private func acceptClient() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        DispatchQueue.global().async {
            var line: [UInt8] = []
            var byte: UInt8 = 0
            while line.count < 4096, read(client, &byte, 1) == 1, byte != 0x0a { line.append(byte) }
            let command = String(decoding: line, as: UTF8.self)
            DispatchQueue.main.async { self.onCommand?(command, ControlConnection(fd: client)) }
        }
    }
}

enum Client {
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = makeAddress()
        guard withSockaddr(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Sends one command and copies the reply to stdout until the daemon closes the connection.
    static func run(_ arguments: [String]) -> Int32 {
        guard let fd = connect() else {
            FileHandle.standardError.write("rzmacro daemon is not running (start it with `open -a RZMacro` or `rzmacro daemon`)\n".data(using: .utf8)!)
            return 1
        }
        let command = Array((arguments.joined(separator: " ") + "\n").utf8)
        _ = command.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            FileHandle.standardOutput.write(Data(buffer[0..<count]))
        }
        close(fd)
        return 0
    }
}
