import Foundation

/// Coalesces overlapping reads and remembers denial as well as success until an explicit retry.
@MainActor
final class CredentialReadGate {
    private var results: [String: Result<Data?, Error>] = [:]
    private var pending: [String: (UUID, Task<Data?, Error>)] = [:]

    func load(_ key: String, read: @escaping () async throws -> Data?) async throws -> Data? {
        if let result = results[key] { return try result.get() }
        if let (_, task) = pending[key] { return try await task.value }
        let generation = UUID()
        let task = Task { try await read() }
        pending[key] = (generation, task)
        let result = await task.result
        if pending[key]?.0 == generation {
            pending[key] = nil
            results[key] = result
        }
        return try result.get()
    }

    func seed(_ key: String, data: Data) {
        invalidate(key)
        results[key] = .success(data)
    }

    func invalidate(_ key: String) {
        results[key] = nil
        // An old in-flight read must not repopulate the cache after a credential update.
        pending[key] = nil
    }
}

/// Update failure must never turn into deletion or replacement of a saved credential.
enum CredentialWritePolicy {
    static func save(missingStatus: Int32, update: () -> Int32, add: () -> Int32) -> Int32 {
        let result = update()
        return result == missingStatus ? add() : result
    }
}
