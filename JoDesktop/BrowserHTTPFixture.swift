#if targetEnvironment(macCatalyst) && (JO_QA || JO_TESTING)
import Foundation
import Network

final class BrowserHTTPFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Jo.browser.fixture")
    private var listener: NWListener?
    private var submissions: [String: Int] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port, !resumed {
                    resumed = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                } else if case .failed(let error) = state, !resumed {
                    resumed = true; continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }; connections.removeAll()
        }
    }
    func count(_ key: String) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.submissions[key, default: 0]) }
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] next, _, done, error in
            guard let self else { return }
            let accumulated = data + (next ?? Data())
            let request = String(decoding: accumulated, as: UTF8.self)
            guard let end = request.range(of: "\r\n\r\n") else {
                if !done, error == nil { self.receive(connection, data: accumulated) }
                return
            }
            let headers = String(request[..<end.lowerBound])
            let length = headers.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("content-length:")
            }.flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            if request[end.upperBound...].utf8.count < length, !done, error == nil {
                self.receive(connection, data: accumulated); return
            }
            let line = headers.components(separatedBy: "\r\n")[0].split(separator: " ")
            let method = line.first.map(String.init) ?? "GET"
            let target = line.count > 1 ? String(line[1]) : "/"
            let path = target.components(separatedBy: "?")[0]
            let key = target.components(separatedBy: "?").last ?? ""
            let body: String
            if method == "POST" {
                self.submissions[key, default: 0] += 1
                body = "Request received; host approval pending."
            } else if path == "/times" { body = "Tuesday 10 am; Wednesday 2 pm. Host approval required." }
            else if path == "/login" { body = "<h1>Fixture sign in</h1><input type='password' name='password'><button>Sign in</button>" }
            else {
                body = Self.page.replacingOccurrences(of: "RECEIPT_EXPRESSION",
                    with: path == "/unknown" ? "'Waiting for confirmation'" : "await r.text()")
            }
            let bytes = Data(body.utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
            let send = {
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel(); self.connections[ObjectIdentifier(connection)] = nil
                })
            }
            if path == "/slow" { self.queue.asyncAfter(deadline: .now() + 2, execute: send) } else { send() }
        }
    }
    private static let page = #"""
    <!doctype html><html><head><title>Jo controlled browser</title></head><body>
    <h1>Controlled Jo browser fixture</h1><p id="isolation"></p>
    <button type="button" id="details" onclick="fetch('/times').then(r=>r.text()).then(t=>document.getElementById('times').innerText=t)">See times</button>
    <div id="times"></div><form id="form"><label>Name <input name="guest" aria-label="Guest name"></label><button type="submit">Request place</button></form><p id="receipt"></p>
    <script>document.getElementById('isolation').innerText=localStorage.getItem('owner')||'Unclaimed browser';
    document.getElementById('form').onsubmit=async e=>{e.preventDefault();const r=await fetch('/submit'+location.search,{method:'POST',body:new FormData(e.target)});document.getElementById('receipt').innerText=RECEIPT_EXPRESSION;};</script></body></html>
    """#
}
#endif
