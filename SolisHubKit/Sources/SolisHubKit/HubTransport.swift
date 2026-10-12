import Foundation

public enum HubTransportError: Error, Equatable, Sendable {
    /// The upgrade was refused with this HTTP status: 401 from the hub, 403
    /// from Cloudflare Access, 429 when the hub is rate limiting.
    case httpStatus(Int)
    case closed(code: Int, reason: String?)
    case connectionFailed(String)
    case timedOut
    case unexpectedFrame
}

/// One open WebSocket. The seam between HubClient and URLSession, so the
/// reconnect and backoff behaviour can be tested with a scripted fake.
public protocol HubSocket: Sendable {
    func send(_ text: String) async throws
    /// Suspends until the next text frame, and throws once the socket is
    /// closed for any reason.
    func receive() async throws -> String
    /// Idempotent. Must make a pending `receive()` throw, because that is how
    /// HubClient stops a reader it can no longer cancel.
    func close()
}

public protocol HubTransport: Sendable {
    func open(_ endpoint: HubEndpoint, headers: [String: String]) async throws -> any HubSocket
}

/// Refuses every redirect. URLSession would otherwise follow one and carry the
/// bearer token and Cloudflare headers to whatever host it names, so a hub
/// that answers with a redirect is reported as a failure instead.
final class RefuseRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class URLSessionHubTransport: HubTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // HubClient owns reconnection and its own timeouts; a session that
        // quietly waits for connectivity would hide an unreachable hub.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(
            configuration: configuration, delegate: RefuseRedirectsDelegate(), delegateQueue: nil
        )
    }

    deinit {
        // The session retains its delegate until it is invalidated.
        session.finishTasksAndInvalidate()
    }

    public func open(_ endpoint: HubEndpoint, headers: [String: String]) async throws -> any HubSocket {
        var request = URLRequest(url: endpoint.webSocketURL)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        // A snapshot carrying the event log and an Octopus plan is far below
        // this, but the default of 1 MiB is not a limit worth meeting.
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        return URLSessionHubSocket(task: task)
    }
}

final class URLSessionHubSocket: HubSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var isClosed = false
    private var pending: [UUID: CheckedContinuation<String, Error>] = [:]

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: HubTransportError.connectionFailed("closed"))
                return
            }
            pending[id] = continuation
            lock.unlock()
            task.receive { [self] result in
                finish(id, result)
            }
        }
    }

    /// Whichever of the callback and `close()` gets here first resumes the
    /// caller; the other finds the entry gone.
    private func finish(_ id: UUID, _ result: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case let .success(.string(text)):
            continuation.resume(returning: text)
        case let .success(.data(data)):
            if let text = String(data: data, encoding: .utf8) {
                continuation.resume(returning: text)
            } else {
                continuation.resume(throwing: HubTransportError.unexpectedFrame)
            }
        case .success:
            continuation.resume(throwing: HubTransportError.unexpectedFrame)
        case let .failure(error):
            continuation.resume(throwing: describe(error))
        }
    }

    /// Cancelling a task whose upgrade has not finished does not always make
    /// its pending receive call back, and a receive that never returns wedges
    /// the client for good: the address list changing mid-handshake, which
    /// Bonjour resolving the chosen hub does on every launch, hung it with no
    /// error and no retry. So the pending receives are failed here, not left to
    /// URLSession.
    func close() {
        lock.lock()
        isClosed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        task.cancel(with: .normalClosure, reason: nil)
        for continuation in waiting.values {
            continuation.resume(throwing: HubTransportError.connectionFailed("closed"))
        }
    }

    /// URLSession reports a refused upgrade as a generic bad-response error;
    /// the status and the close code are on the task.
    private func describe(_ error: Error) -> HubTransportError {
        if let response = task.response as? HTTPURLResponse, response.statusCode >= 400 {
            return .httpStatus(response.statusCode)
        }
        if task.closeCode != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            return .closed(code: task.closeCode.rawValue, reason: reason)
        }
        return .connectionFailed((error as NSError).localizedDescription)
    }
}
