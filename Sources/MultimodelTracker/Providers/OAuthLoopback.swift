import Foundation
import CryptoKit
import Network

/// The pieces both browser sign-in flows share: the PKCE material and the
/// one-shot loopback listener that catches the OAuth redirect. OpenAI and
/// Anthropic differ only in endpoints and token-request encoding.

enum OAuthPKCE {
    static func randomURLSafe(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return Data(raw).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum LoopbackError: LocalizedError {
    case portBusy
    case cancelled
    case badCallback(String)

    var errorDescription: String? {
        switch self {
        case .portBusy:          return "The sign-in port is busy — retry in a moment."
        case .cancelled:         return "Sign-in was cancelled or timed out."
        case .badCallback(let s): return "Sign-in was rejected: \(s)"
        }
    }
}

/// A one-shot loopback HTTP listener for the OAuth redirect. Deliberately
/// minimal: read the request line, answer once, stop.
///
/// Port 0 asks the system for an ephemeral port — Anthropic (like Claude Code
/// itself) registers the loopback redirect for ANY localhost port, so there is
/// no fixed number to fight over. OpenAI's client is registered against
/// exactly :1455, so that flow has to bind it or fail.
final class LoopbackCatcher: @unchecked Sendable {
    private let listener: NWListener
    private let expectedState: String
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private let lock = NSLock()

    /// Bind state. NWListener reports "port already in use" ASYNCHRONOUSLY via
    /// .failed — the throwing init only catches malformed parameters — so a
    /// busy port must be surfaced here, not assumed caught at construction.
    private var readyResult: Result<UInt16, Error>?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?

    init(port: UInt16, expectedState: String) throws {
        self.expectedState = expectedState
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            if port == 0 {
                listener = try NWListener(using: params)
            } else {
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LoopbackError.portBusy }
                listener = try NWListener(using: params, on: nwPort)
            }
        } catch { throw LoopbackError.portBusy }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.finishReady(.success(self?.listener.port?.rawValue ?? port))
            case .failed, .cancelled:
                self?.finishReady(.failure(LoopbackError.portBusy))
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    /// Resolves once the socket is actually listening, with the bound port.
    /// Await this BEFORE opening the browser: a fast redirect into a port
    /// that has not finished binding is silently lost.
    func ready() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let done = readyResult {
                lock.unlock()
                cont.resume(with: done)
                return
            }
            readyContinuation = cont
            lock.unlock()
        }
    }

    private func finishReady(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard readyResult == nil else { lock.unlock(); return }
        readyResult = result
        let cont = readyContinuation
        readyContinuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    func awaitCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            // The browser may never come back (tab closed); don't hang forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(.failure(LoopbackError.cancelled))
            }
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value
            let state = items.first { $0.name == "state" }?.value
            let err = items.first { $0.name == "error" }?.value

            let ok = err == nil && code != nil && state == self.expectedState
            let message = ok
                ? "Signed in. You can close this tab and return to Multimodel Tracker."
                : "Sign-in failed: \(err ?? "unexpected response"). Return to Multimodel Tracker and try again."
            let html = "<!doctype html><meta charset=utf-8><title>Multimodel Tracker</title>"
                + "<body style=\"font:15px -apple-system,system-ui;margin:60px auto;max-width:32em\">"
                + "<p>\(message)</p></body>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })

            if ok, let code {
                self.finish(.success(code))
            } else if err != nil || code != nil {
                // Only fail on a real callback; ignore favicon and stray hits.
                self.finish(.failure(LoopbackError.badCallback(err ?? "state mismatch")))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        lock.unlock()
        cont.resume(with: result)
        listener.cancel()
    }
}
