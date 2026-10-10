import Foundation
import Network
import Combine

struct ClaudeUsageEvent: Codable {
    let account: String
    let organization: String
    let request: String
    let model: String
    let time: Date
    let tokens: Double
    var key: String { "\(organization)/\(account)/\(request)" }
}

/// OTLP/HTTP JSON logs only. Persists a strict allowlist of usage metadata, never log bodies.
enum ClaudeTelemetryParser {
    static func attributes(_ entries: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for entry in entries {
            guard let key = entry["key"] as? String, let value = entry["value"] as? [String: Any] else { continue }
            result[key] = value["stringValue"] ?? value["intValue"] ?? value["doubleValue"]
        }
        return result
    }
    static func parse(_ data: Data) throws -> [ClaudeUsageEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = root["resourceLogs"] as? [[String: Any]] else { throw AdapterError.transport("Expected OTLP logs") }
        var events: [ClaudeUsageEvent] = []
        for resource in resources {
            let base = attributes((resource["resource"] as? [String: Any])?["attributes"] as? [[String: Any]] ?? [])
            for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
                for log in scope["logRecords"] as? [[String: Any]] ?? [] {
                    let a = base.merging(attributes(log["attributes"] as? [[String: Any]] ?? [])) { _, new in new }
                    let name = a["event.name"] as? String ?? ""
                    guard name == "api_request" || name == "claude_code.api_request",
                          let account = a["user.account_uuid"] as? String, UUID(uuidString: account) != nil,
                          let org = a["organization.id"] as? String, !org.isEmpty,
                          let request = a["request_id"] as? String, !request.isEmpty,
                          let model = a["model"] as? String, !model.isEmpty else { continue }
                    let nanos = Double(String(describing: log["timeUnixNano"] ?? ""))
                    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let stamp = a["event.timestamp"] as? String ?? ""
                    guard let date = nanos.map({ Date(timeIntervalSince1970: $0/1e9) }) ?? f.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp),
                          date > Date().addingTimeInterval(-30*86400), date < Date().addingTimeInterval(300) else { continue }
                    let values = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"].map { key -> Double in
                        Double(String(describing: a[key] ?? "0")) ?? -1
                    }
                    guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1e12 }) else { continue }
                    events.append(.init(account: account.lowercased(), organization: org.lowercased(), request: request,
                                        model: String(model.prefix(200)), time: date, tokens: values.reduce(0,+)))
                }
            }
        }
        return events
    }
}

actor ClaudeUsageLedger {
    static let shared = ClaudeUsageLedger()
    private var events: [String: ClaudeUsageEvent] = [:]
    private var loaded = false
    private let file: URL
    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MultimodelTracker/claude-usage.json")) { self.file = file }
    private func load() {
        guard !loaded else { return }; loaded = true
        if let d = try? Data(contentsOf: file), let rows = try? JSONDecoder().decode([ClaudeUsageEvent].self, from: d) {
            for e in rows { events[e.key] = e }
        }
    }
    func ingest(_ data: Data) throws {
        let incoming = try ClaudeTelemetryParser.parse(data); load()
        for e in incoming { events[e.key] = e }
        let kept = events.values.filter { $0.time > Date().addingTimeInterval(-30*86400) }.sorted { $0.time > $1.time }.prefix(100_000)
        events = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Array(events.values)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func hasEvents() -> Bool { load(); return !events.isEmpty }

    func report(account: String, organization: String) -> UsageDetails {
        load(); var totals: [String: Double] = [:]
        for e in events.values where e.account == account.lowercased() && e.organization == organization.lowercased() && e.time > Date().addingTimeInterval(-7*86400) {
            totals[e.model, default: 0] += e.tokens
        }
        return UsageDetails(title: "Claude Code · last 7 days", rows: totals.map { .init(model: $0.key, value: $0.value) }.sorted { $0.value > $1.value },
                            note: "Captured on this Mac while the tracker is running. Includes cached tokens. Uses event account + organization IDs. Missing-identity events are excluded; no historical backfill.")
    }
}

/// Explicit opt-in setup preserves unrelated Claude settings and refuses to replace another exporter.
@MainActor
final class ClaudeTelemetry: ObservableObject {
    static let shared = ClaudeTelemetry()
    static let port: UInt16 = 43189
    @Published var status = "Local Claude Code collection is off."
    @Published var enabled = UserDefaults.standard.bool(forKey: "mmt.claudeTelemetry")
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mmt.telemetry")
    private var secret: String {
        if let saved = UserDefaults.standard.string(forKey: "mmt.telemetrySecret") { return saved }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: "mmt.telemetrySecret"); return value
    }
    func enable() {
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw AdapterError.transport("Claude settings must be a JSON object") }
                root = obj
            }
            if root["env"] != nil && !(root["env"] is [String: Any]) { throw AdapterError.transport("Claude env settings must be an object") }
            var env = root["env"] as? [String: Any] ?? [:]
            let endpoint = "http://127.0.0.1:\(Self.port)/v1/logs"
            if let exporter = env["OTEL_LOGS_EXPORTER"] as? String, exporter != "none",
               env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] as? String != endpoint {
                throw AdapterError.transport("Existing Claude log exporter preserved. Configure a collector fan-out to add this tracker.")
            }
            let settings = ["CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOGS_EXPORTER": "otlp",
                            "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": endpoint,
                            "OTEL_EXPORTER_OTLP_LOGS_HEADERS": "Authorization=Bearer \(secret)",
                            "OTEL_LOG_USER_PROMPTS": "0", "OTEL_LOG_ASSISTANT_RESPONSES": "0", "OTEL_LOG_TOOL_DETAILS": "0", "OTEL_LOG_RAW_API_BODIES": "0"]
            let previous = try JSONSerialization.data(withJSONObject: env.filter { settings[$0.key] != nil })
            if !enabled { UserDefaults.standard.set(previous, forKey: "mmt.telemetryPreviousEnv") }
            UserDefaults.standard.set(settings, forKey: "mmt.telemetryInstalledEnv")
            for (k,v) in settings { env[k] = v }
            root["env"] = env
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("mmt-\(Int(Date().timeIntervalSince1970)).bak")
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            enabled = true; UserDefaults.standard.set(true, forKey: "mmt.claudeTelemetry")
            start()
        } catch { status = String(describing: error) }
    }
    func disable() {
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            var env = root["env"] as? [String: Any] ?? [:]
            let previous = UserDefaults.standard.data(forKey: "mmt.telemetryPreviousEnv")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let installed = UserDefaults.standard.dictionary(forKey: "mmt.telemetryInstalledEnv") ?? [:]
            for (key, value) in installed where env[key] as? String == value as? String {
                env[key] = previous[key]
            }
            root["env"] = env
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            listener?.cancel(); listener = nil; enabled = false
            UserDefaults.standard.set(false, forKey: "mmt.claudeTelemetry")
            status = "Collection stopped. Restart Claude Code to apply settings."
        } catch { status = "Could not restore Claude settings: \(error.localizedDescription)" }
    }
    func start() {
        // Retain only values this feature overwrote, including after upgrading an earlier build.
        if let data = UserDefaults.standard.data(forKey: "mmt.telemetryPreviousEnv"),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let installed = UserDefaults.standard.dictionary(forKey: "mmt.telemetryInstalledEnv"),
           let trimmed = try? JSONSerialization.data(withJSONObject: previous.filter { installed[$0.key] != nil }) {
            UserDefaults.standard.set(trimmed, forKey: "mmt.telemetryPreviousEnv")
        }
        guard enabled, listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let l = try NWListener(using: params); listener = l
            let auth = "Bearer \(secret)"
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.status = "Collecting locally. Restart Claude Code to apply settings." }
                    if case .failed = state { self?.status = "Local collector could not start; port \(Self.port) may be in use."; self?.listener = nil }
                }
            }
            l.newConnectionHandler = { connection in
                let receiver = ClaudeTelemetryConnection(connection, authorization: auth)
                receiver.start()
            }
            l.start(queue: queue)
        } catch { listener = nil; status = "Unable to start local collection: \(error.localizedDescription)" }
    }
}

private final class ClaudeTelemetryConnection {
    let connection: NWConnection
    let authorization: String
    var buffer = Data()
    init(_ connection: NWConnection, authorization: String) { self.connection = connection; self.authorization = authorization }
    func start() {
        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now()+10) { [weak self] in self?.connection.cancel() }
        read()
    }
    func reply(_ status: String) {
        let body = "{}"
        connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n\(body)".utf8), completion: .contentProcessed { [self] _ in connection.cancel() })
    }
    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            guard buffer.count <= 8*1024*1024 else { reply("413 Payload Too Large"); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard end.lowerBound < 16384, let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { reply("400 Bad Request"); return }
                let lines = header.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pieces = line.split(separator: ":", maxSplits: 1)
                    if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
                }
                guard lines.first == "POST /v1/logs HTTP/1.1", headers["authorization"] == authorization else { reply("403 Forbidden"); return }
                guard headers["transfer-encoding"] == nil, let n = Int(headers["content-length"] ?? ""), n >= 0, n <= 8*1024*1024 else { reply("411 Length Required"); return }
                if buffer.count >= end.upperBound+n {
                    let payload = Data(buffer[end.upperBound..<(end.upperBound+n)])
                    Task {
                        do { try await ClaudeUsageLedger.shared.ingest(payload); reply("200 OK") }
                        catch { reply("400 Bad Request") }
                    }
                    return
                }
            } else if buffer.count > 16384 { reply("431 Request Header Fields Too Large"); return }
            if done || error != nil { connection.cancel() } else { read() }
        }
    }
}
