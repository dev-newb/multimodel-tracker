import Foundation

@main
struct CredentialReadGateTests {
    enum Denied: Error { case access }
    @MainActor static func main() async throws {
        let gate = CredentialReadGate()
        var calls = 0
        let denied: () async throws -> Data? = {
            calls += 1
            await Task.yield()
            throw Denied.access
        }
        async let a = gate.load("account-A", read: denied)
        async let b = gate.load("account-A", read: denied)
        do { _ = try await a; fatalError("Expected denial") } catch { }
        do { _ = try await b; fatalError("Expected denial") } catch { }
        precondition(calls == 1, "Overlapping callers must share one read")
        do { _ = try await gate.load("account-A", read: denied); fatalError("Expected cached denial") } catch { }
        precondition(calls == 1, "Polling must not repeat denied requests")
        gate.invalidate("account-A")
        let data = try await gate.load("account-A") { calls += 1; return Data([1]) }
        precondition(data == Data([1]) && calls == 2, "Explicit retry must read again")
        let other = try await gate.load("account-B") { Data([2]) }
        precondition(other == Data([2]), "Accounts must stay isolated")

        var continuation: CheckedContinuation<Data?, Never>?
        let old = Task { try await gate.load("changing") {
            await withCheckedContinuation { continuation = $0 }
        } }
        while continuation == nil { await Task.yield() }
        gate.invalidate("changing")
        _ = try await gate.load("changing") { Data([9]) }
        continuation?.resume(returning: Data([8]))
        _ = try await old.value
        let after = try await gate.load("changing") { fatalError("Expected new cached value") }
        precondition(after == Data([9]), "Old read must not overwrite a newer credential")

        gate.seed("saved", data: Data([5]))
        let saved = try await gate.load("saved") { fatalError("A successful write must not immediately reread Keychain") }
        precondition(saved == Data([5]))

        var adds = 0
        let failed = CredentialWritePolicy.save(missingStatus: -25300, update: { -25293 }, add: { adds += 1; return 0 })
        precondition(failed == -25293 && adds == 0, "Access denial must preserve the old item")
        let updated = CredentialWritePolicy.save(missingStatus: -25300, update: { 0 }, add: { adds += 1; return 0 })
        precondition(updated == 0 && adds == 0, "Existing items must be updated in place")
        let added = CredentialWritePolicy.save(missingStatus: -25300, update: { -25300 }, add: { adds += 1; return -25299 })
        precondition(added == -25299 && adds == 1, "Add only when missing; propagate errors")
        print("PASS: one concurrent read, denial caching, explicit retry, account isolation, invalidation race, non-destructive save/error propagation. No real Keychain access.")
    }
}
