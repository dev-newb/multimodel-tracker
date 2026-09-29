import Foundation
import Darwin

/// Antigravity can point its language server at Google's DAILY service
/// instead of production (`--cloud_code_endpoint`), and the two report
/// different quota balances. The tracker follows whichever the installed
/// client is using, never choosing a host by which balance looks better.
///
/// That choice exists only in the language server's process arguments --
/// nothing on disk records it (checked: Application Support, ~/.gemini) --
/// so the detection reads argv. It does so through sysctl, which is what
/// `ps` itself does, rather than spawning `ps` twice every thirty seconds
/// from a menu-bar app. A Config choice overrides the detection either way.
enum AntigravityServiceRoute {
    enum Host: String {
        case production = "cloudcode-pa.googleapis.com"
        case daily = "daily-cloudcode-pa.googleapis.com"
        var displayName: String { self == .daily ? "daily" : "production" }
    }
    /// The user's choice in Config: follow Antigravity, or pin a service.
    enum Setting: String, CaseIterable {
        case auto, production, daily
    }
    private static let settingKey = "mmt.antigravityService"
    private static let rememberedKey = "mmt.antigravityServiceHost"

    static var setting: Setting {
        get { Setting(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: settingKey); invalidate() }
    }

    /// The host every Google call goes to.
    static func current() -> Host {
        switch setting {
        case .production: return .production
        case .daily:      return .daily
        case .auto:       return detectedHost() ?? remembered ?? .production
        }
    }

    /// What Antigravity is using right now, or nil when it is not running or
    /// its servers disagree -- shown in Config as "following Antigravity → daily".
    static func detectedHost() -> Host? {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(checkedAt) < 30 { return detected }
        checkedAt = Date()
        detected = scan()
        if let detected { UserDefaults.standard.set(detected.rawValue, forKey: rememberedKey) }
        return detected
    }

    static func invalidate() { lock.lock(); checkedAt = .distantPast; lock.unlock() }

    /// The last host seen live, for when Antigravity is not running.
    private static var remembered: Host? {
        UserDefaults.standard.string(forKey: rememberedKey).flatMap(Host.init(rawValue:))
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
    private static var detected: Host?

    private static func scan() -> Host? {
        var hosts = Set<Host>()
        for pid in processIDs(named: "language_server") {
            let (path, args) = commandLine(of: pid)
            // The binary is language_server_macos_arm (p_comm keeps 16 chars of
            // that), and Codeium ships the same one in Windsurf; only the copy
            // inside Antigravity.app counts.
            guard path.contains("/Antigravity.app/Contents/Resources/bin/language_server") else { continue }
            if let host = host(in: args) { hosts.insert(host) }
        }
        return hosts.count == 1 ? hosts.first : nil
    }

    /// Every process whose short name STARTS with `name`, via KERN_PROC_ALL.
    /// p_comm keeps only 16 characters, so a prefix is all that can be asked.
    static func processIDs(named name: String) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { proc in
            var comm = proc.kp_proc.p_comm          // a local copy: exclusivity forbids pointing at it in place
            let capacity = MemoryLayout.size(ofValue: comm)
            let short = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            return short.hasPrefix(name) ? proc.kp_proc.p_pid : nil
        }
    }

    /// The executable path and argument string of one process, via
    /// KERN_PROCARGS2: an Int32 argc, the exec path, NUL padding, then argv.
    /// Another user's process refuses (EPERM) and reads as empty.
    static func commandLine(of pid: pid_t) -> (path: String, args: String) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ("", "") }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ("", "") }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        let pathStart = i
        while i < size && buffer[i] != 0 { i += 1 }
        let path = String(decoding: buffer[pathStart..<i], as: UTF8.self)
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        var start = i
        while i < size && args.count < argc {
            if buffer[i] == 0 { args.append(String(decoding: buffer[start..<i], as: UTF8.self)); start = i + 1 }
            i += 1
        }
        return (path, args.joined(separator: " "))
    }
}
