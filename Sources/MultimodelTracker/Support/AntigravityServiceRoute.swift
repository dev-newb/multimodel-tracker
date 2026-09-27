import Foundation

/// The stable and daily services can report different quota balances. Follow the
/// installed client's configured service, never choose a host by its usage value.
enum AntigravityServiceRoute {
    enum Host: String {
        case production = "cloudcode-pa.googleapis.com"
        case daily = "daily-cloudcode-pa.googleapis.com"
    }
    static func host(in arguments: String) -> Host? {
        let pattern = #"--cloud_code_endpoint(?:=|\s+)[\"']?https://(cloudcode-pa\.googleapis\.com|daily-cloudcode-pa\.googleapis\.com)(?:[\"'\s/]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)),
              let range = Range(match.range(at: 1), in: arguments) else { return nil }
        return Host(rawValue: String(arguments[range]))
    }
    private static let lock = NSLock()
    private static var checkedAt = Date.distantPast
    private static var cached: Host?
    static func current() -> Host {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(checkedAt) < 30, let cached { return cached }
        checkedAt = Date()
        let known = UserDefaults.standard.string(forKey: "mmt.antigravityServiceHost").flatMap(Host.init(rawValue:))
        let listing = ps(["-axo", "pid=,comm="])
        var hosts = Set<String>()
        for line in listing.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2,
                  fields[1].hasSuffix("/Antigravity.app/Contents/Resources/bin/language_server"),
                  Int(fields[0]) != nil else { continue }
            // Only this process's arguments are read, in memory, and never logged.
            if let host = host(in: ps(["-ww", "-p", String(fields[0]), "-o", "command="])) { hosts.insert(host.rawValue) }
        }
        if hosts.count == 1, let name = hosts.first, let detected = Host(rawValue: name) {
            cached = detected
            UserDefaults.standard.set(name, forKey: "mmt.antigravityServiceHost")
        } else { cached = known ?? .production }
        return cached ?? .production
    }
    private static func ps(_ arguments: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(decoding: data, as: UTF8.self)
        } catch { return "" }
    }
}
