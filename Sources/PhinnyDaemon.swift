import Foundation

/// Error returned by the phinny daemon (carries a machine-readable code, e.g.
/// "chrome_not_installed", so the UI can react specifically).
struct DaemonError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Thin IPC client for the bundled `phinny` Go engine. The app launches
/// `phinny serve --stdio` once and keeps it alive; every read/write/sync goes
/// over this connection as line-delimited JSON-RPC. The daemon holds the SQLite
/// connection open, so calls are fast (no per-command process spawn).
///
/// The protocol is strictly request/response and serialized here on a private
/// queue, matching the daemon's single-writer model.
final class PhinnyDaemon: @unchecked Sendable {
    private let proc = Process()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let queue = DispatchQueue(label: "com.dallinromney.phinny.daemon")
    private var buffer = Data()

    /// Locate the bundled engine binary. Falls back to a PHINNY_BIN env override
    /// for development (e.g. pointing at a freshly `go build`-ed binary).
    static func binaryURL() -> URL? {
        if let u = Bundle.main.url(forResource: "phinny", withExtension: nil) { return u }
        if let p = ProcessInfo.processInfo.environment["PHINNY_BIN"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// The bundled demo database the daemon copies + opens in demo mode.
    static func demoSourceURL() -> URL? {
        Bundle.main.url(forResource: "phinny-demo", withExtension: "sqlite")
    }

    enum LaunchError: LocalizedError {
        case binaryMissing
        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "The bundled phinny engine is missing from the app. Rebuild with scripts/build-app.sh."
            }
        }
    }

    /// Launch the daemon. `forceDemo` opens bundled sample data regardless of any
    /// connected account.
    init(forceDemo: Bool) throws {
        guard let binary = Self.binaryURL() else { throw LaunchError.binaryMissing }

        var args = ["serve", "--stdio"]
        if let demo = Self.demoSourceURL() { args += ["--demo-source", demo.path] }
        if forceDemo { args += ["--demo"] }

        let inPipe = Pipe()
        let outPipe = Pipe()
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading

        proc.executableURL = binary
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.standardError
        try proc.run()
    }

    func shutdown() {
        try? stdinHandle.close()
        if proc.isRunning { proc.terminate() }
    }

    // MARK: - Calls

    /// Call a method with a JSON-object params dictionary; returns the raw
    /// `result` JSON for the caller to decode.
    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> Data {
        let paramsData = params.isEmpty ? nil : try JSONSerialization.data(withJSONObject: params)
        return try await invoke(method, paramsData)
    }

    /// Call a method whose params are an Encodable value (e.g. a Mortgage).
    @discardableResult
    func send<P: Encodable>(_ method: String, encodable params: P) async throws -> Data {
        let paramsData = try JSONEncoder().encode(params)
        return try await invoke(method, paramsData)
    }

    /// Call a method with params already serialized to JSON `Data`. Used by the
    /// ordered write pipeline so a non-Sendable dictionary never crosses an
    /// isolation boundary.
    @discardableResult
    func send(_ method: String, raw paramsData: Data?) async throws -> Data {
        try await invoke(method, paramsData)
    }

    /// Decode a method's result into a Decodable type.
    func decode<T: Decodable>(_ type: T.Type, _ method: String, _ params: [String: Any] = [:]) async throws -> T {
        let data = try await send(method, params)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func invoke(_ method: String, _ paramsData: Data?) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.syncCall(method, paramsData)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func syncCall(_ method: String, _ paramsData: Data?) throws -> Data {
        guard proc.isRunning else {
            throw DaemonError(code: "daemon_down", message: "The phinny engine stopped running.")
        }
        var request: [String: Any] = ["method": method]
        if let paramsData, let obj = try? JSONSerialization.jsonObject(with: paramsData) {
            request["params"] = obj
        }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)

        let respData = try readLine()
        let obj = try JSONSerialization.jsonObject(with: respData) as? [String: Any] ?? [:]
        if let err = obj["error"] as? [String: Any] {
            throw DaemonError(
                code: err["code"] as? String ?? "error",
                message: err["message"] as? String ?? "Unknown error")
        }
        let result = obj["result"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    /// Read one newline-delimited response from the daemon, buffering any extra.
    private func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                return line
            }
            // Use a POSIX read(2) on the file descriptor rather than
            // FileHandle.read(upToCount:). The latter can block indefinitely on
            // the trailing partial chunk of a large pipe response (e.g. the
            // ~220KB `state` snapshot): after consuming a few 64KB chunks it
            // stops returning the remaining bytes already sitting in the pipe.
            // POSIX read returns as soon as any bytes are available.
            var tmp = [UInt8](repeating: 0, count: 65536)
            let n = tmp.withUnsafeMutableBytes { Foundation.read(stdoutHandle.fileDescriptor, $0.baseAddress, 65536) }
            if n < 0 {
                throw DaemonError(code: "daemon_read", message: "Reading from the phinny engine failed.")
            }
            if n == 0 {
                throw DaemonError(code: "daemon_eof", message: "The phinny engine closed the connection.")
            }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }
}
