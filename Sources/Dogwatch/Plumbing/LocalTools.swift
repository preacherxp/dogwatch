import Foundation

/// Decides whether a provider may start a program. The real gate allows only the provider's
/// declared commands; tests use a gate that records every attempt.
protocol CommandGate {
    /// Returns the program to run, or throws `.commandNotAllowed` / `.notInstalled`.
    func authorize(_ command: DeclaredCommand, tools: LocalTools) throws -> URL
}

struct DeclaredCommandGate: CommandGate {
    let declared: [DeclaredCommand]

    func authorize(_ command: DeclaredCommand, tools: LocalTools) throws -> URL {
        guard declared.contains(command) else {
            throw ProviderError.commandNotAllowed(([command.executable] + command.arguments).joined(separator: " "))
        }
        guard let url = tools.findExecutable(named: command.executable, extraDirectories: tools.commonToolDirectories) else {
            throw ProviderError.notInstalled("\(command.executable) is not installed.")
        }
        return url
    }
}

/// Local files, logs and commands, for providers that read another tool's own data. Reading
/// is the only file access there is: nothing here can write, move or delete another tool's
/// files. Commands go through the gate and never through a shell.
struct LocalTools {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var gate: CommandGate = DeclaredCommandGate(declared: [])

    struct CommandResult {
        let status: Int32
        let output: Data
    }

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// The items in a folder, newest first, for providers that pick the newest of several files
    /// (one per IDE version). Read-only; an empty list when the folder is missing. Hidden items
    /// are left out.
    func contents(of folder: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return items.sorted { modified($0) > modified($1) }
    }

    /// The last `maxBytes` of a growing log, so a large file is never read whole.
    func tail(of url: URL, maxBytes: Int = 1_048_576) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return Data() }
        try handle.seek(toOffset: size - min(size, UInt64(maxBytes)))
        return handle.readDataToEndOfFile()
    }

    /// The program for a declared command, checked by the gate. Providers with a long-lived
    /// conversation (a JSON-RPC server on stdin/stdout) start it themselves from this URL,
    /// with `processEnvironment(for:)`.
    func authorize(_ command: DeclaredCommand) throws -> URL {
        try gate.authorize(command, tools: self)
    }

    /// The environment for a started tool: the user's, with the usual install folders on `PATH`,
    /// no browser, and the command's own overrides.
    func processEnvironment(for command: DeclaredCommand) -> [String: String] {
        var env = environment
        env["PATH"] = (commonToolDirectories + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env["BROWSER"] = "/usr/bin/false"
        for (name, value) in command.environment { env[name] = value }
        return env
    }

    /// Runs a declared command to completion, without a shell, in a temporary folder, and
    /// returns its exit status and standard output. Standard error is discarded.
    func run(_ command: DeclaredCommand, timeout: TimeInterval = 30) async throws -> CommandResult {
        let executable = try authorize(command)
        let environment = processEnvironment(for: command)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = command.arguments
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProviderError.notInstalled("\(command.executable) could not be started."))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ProviderError.timedOut)
                } else {
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: data))
                }
            }
        }
    }

    /// The first executable named `name` in `PATH` or the extra folders. Apps started from
    /// Finder don't get the shell's `PATH`, so providers pass the usual install folders.
    func findExecutable(named name: String, extraDirectories: [String] = []) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (pathDirectories + extraDirectories)
            .map { "\($0)/\(name)" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    /// Install folders GUI apps miss: Homebrew, `~/.local/bin`, npm's and nvm's.
    var commonToolDirectories: [String] {
        var entries = ["/usr/local/bin", "/opt/homebrew/bin", "\(home.path)/.node_modules/bin", "\(home.path)/.local/bin"]
        for root in ["\(home.path)/.local/share/nvm", "\(home.path)/.nvm/versions/node"] {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            entries.append(contentsOf: versions.map { "\(root)/\($0)/bin" })
        }
        return entries
    }
}

enum DateParsing {
    /// ISO 8601 with or without fractional seconds, with `Z` or an offset, or a date alone.
    static func iso8601(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        if let date = formatter.date(from: raw.replacingOccurrences(of: "+00:00", with: "Z")) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: raw)
    }

    /// Seconds or milliseconds since 1970; values above 10^11 are taken as milliseconds.
    static func epoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// A JSON value that is either an ISO 8601 string or an epoch number.
    static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .string(let text)?: return iso8601(text) ?? Double(text).flatMap(epoch)
        case .number(let number)?: return epoch(number)
        default: return nil
        }
    }
}
