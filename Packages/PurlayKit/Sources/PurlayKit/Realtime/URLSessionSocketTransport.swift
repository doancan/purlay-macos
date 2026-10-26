import Foundation
import Synchronization

/// The real socket: one `URLSessionWebSocketTask` per connection, with the headers the server needs of a client that is not a
/// browser (§9.1): the session as an explicit `Cookie`, `Origin` equal to the server's own address, and the client's version.
/// No token in the address (`ARCHITECTURE.md` §7.2). Each socket has a session of its own, so closing one cannot touch another.
public struct URLSessionSocketTransport {
    public let cookie: @Sendable () async -> String?
    public let cookieName: String
    public let origin: String
    public let clientHeader: String

    public init(
        origin: String, clientHeader: String, cookieName: String = "__Host-purlay_session",
        cookie: @escaping @Sendable () async -> String?
    ) {
        self.origin = origin
        self.clientHeader = clientHeader
        self.cookieName = cookieName
        self.cookie = cookie
    }

    /// The upgrade request: what is sent is decided here and nowhere else.
    public func request(for url: URL, session: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("\(cookieName)=\(session)", forHTTPHeaderField: "Cookie")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(clientHeader, forHTTPHeaderField: "X-Purlay-Client")
        request.timeoutInterval = 15
        return request
    }

    /// The address of the socket, from the server's own address: `https` → `wss`, `http` → `ws`, path `/ws`.
    public static func socketURL(for server: URL) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = "/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// An `OpenSocket` for a `Connection`. The session is read when the socket is opened; none, and nothing is opened.
    @MainActor
    public func openSocket(session: String) -> OpenSocket {
        { url, handlers in
            let socket = URLSessionSocket(request: request(for: url, session: session), handlers: handlers)
            socket.start()
            return socket
        }
    }
}

/// What a socket's delegate reports, to be handled on the main actor where the connection lives.
enum SocketEvent: Sendable {
    case opened
    case message(String)
    case closed(Int)
    case refused(Int)
    /// The task is over. For a socket that never opened this is where a refused upgrade is found.
    case completed
}

@MainActor
final class URLSessionSocket: SocketHandle {
    private let handlers: SocketHandlers
    private let delegate: SocketDelegate
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var finished = false
    private var opened = false

    init(request: URLRequest, handlers: SocketHandlers) {
        self.handlers = handlers
        let sink = EventSink()
        let delegate = SocketDelegate(sink: sink)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // `maximumMessageSize` bounds what one frame may be: the server never sends more than a page of messages.
        task.maximumMessageSize = 4 * 1_024 * 1_024
        sink.connect { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func start() {
        task.resume()
    }

    private func receive() {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let value): text = value
                // The contract is text. Binary is delivered as nothing, which the connection reads as "not a frame".
                case .data: text = ""
                @unknown default: text = ""
                }
                Task { @MainActor in
                    guard let self, !self.finished else { return }
                    self.handlers.message(text)
                    self.receive()
                }
            case .failure:
                Task { @MainActor in self?.failed() }
            }
        }
    }

    /// The receive loop ended: the socket closed, or never opened. Which, and why, is what the task knows.
    private func failed() {
        guard !finished else { return }
        if !opened, let response = task.response as? HTTPURLResponse, response.statusCode >= 400 {
            finish { $0.refused(response.statusCode) }
            return
        }
        let code = task.closeCode.rawValue
        // 0 is "no code": the connection dropped without a close frame, as the network does.
        finish { $0.closed(code == 0 ? 1006 : code) }
    }

    private func finish(_ report: (SocketHandlers) -> Void) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()
        report(handlers)
    }

    fileprivate func handle(_ event: SocketEvent) {
        guard !finished else { return }
        switch event {
        case .opened:
            opened = true
            handlers.opened()
            receive()
        case .message(let text):
            handlers.message(text)
        case .closed(let code):
            finish { $0.closed(code == 0 ? 1006 : code) }
        case .refused(let status):
            finish { $0.refused(status) }
        case .completed:
            failed()
        }
    }

    // MARK: SocketHandle

    func send(_ text: String) {
        task.send(.string(text)) { _ in
            // A send that failed is a socket that is going: the receive loop reports it.
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Where the delegate's reports go once the socket that owns it exists: the delegate is made first, because the session needs
/// it, and the socket second, because it needs the session.
final class EventSink: Sendable {
    private let handler = Mutex<(@Sendable (SocketEvent) -> Void)?>(nil)

    func connect(_ next: @escaping @Sendable (SocketEvent) -> Void) {
        handler.withLock { $0 = next }
    }

    func send(_ event: SocketEvent) {
        let current = handler.withLock { $0 }
        current?(event)
    }
}

/// Reports what the task does. Not isolated: the system calls it on its own queue.
final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    let sink: EventSink

    init(sink: EventSink) {
        self.sink = sink
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        sink.send(.opened)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        sink.send(.closed(closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        sink.send(.completed)
    }
}
