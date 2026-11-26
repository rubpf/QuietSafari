import Foundation
import Network

/// Serves one static HTML page on 127.0.0.1 so Safari (not this app) can load it
/// and the extensions can prove they are active. Nothing is accepted from the network.
final class TestPageServer {
    private let queue = DispatchQueue(label: "com.quietsafari.testpage")
    private let lock = NSLock()
    private var listener: NWListener?
    private var html = ""
    private var boundURL: URL?

    func start(html: String) throws -> URL {
        lock.lock()
        self.html = html
        if let boundURL {
            lock.unlock()
            return boundURL
        }
        lock.unlock()

        var lastError: Error?
        for portNumber in 8765 ... 8770 {
            do {
                let url = try bind(port: UInt16(portNumber))
                lock.lock()
                boundURL = url
                lock.unlock()
                return url
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TestPageError.couldNotBind
    }

    private func bind(port portNumber: UInt16) throws -> URL {
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            throw TestPageError.couldNotBind
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        let gate = StartGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.finish(error: nil)
            case .failed(let error):
                gate.finish(error: error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.lock()
            let page = self.html
            self.lock.unlock()
            self.serve(connection, html: page)
        }
        listener.start(queue: queue)
        let signaled = gate.semaphore.wait(timeout: .now() + 2)
        listener.stateUpdateHandler = nil
        if signaled == .timedOut {
            listener.cancel()
            throw TestPageError.couldNotBind
        }
        if let error = gate.error {
            listener.cancel()
            throw error
        }
        self.listener = listener
        return URL(string: "http://127.0.0.1:\(portNumber)/")!
    }

    private func serve(_ connection: NWConnection, html: String) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
            let body = Data(html.utf8)
            let header = [
                "HTTP/1.1 200 OK",
                "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(body.count)",
                "Connection: close",
                "Cache-Control: no-store",
                "",
                "",
            ].joined(separator: "\r\n")
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class StartGate {
    let semaphore = DispatchSemaphore(value: 0)
    private(set) var error: Error?
    private var finished = false

    func finish(error: Error?) {
        if finished {
            return
        }
        finished = true
        self.error = error
        semaphore.signal()
    }
}

enum TestPageError: LocalizedError {
    case missingPage
    case couldNotBind

    var errorDescription: String? {
        switch self {
        case .missingPage:
            return "В приложении нет проверочной страницы."
        case .couldNotBind:
            return "Не удалось открыть локальный порт для проверочной страницы."
        }
    }
}
