import Foundation
import LauncherCore
import Network

struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var requestID: String
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        do {
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json; charset=utf-8"
            return HTTPResponse(status: status, headers: responseHeaders, body: try LauncherJSON.encoder().encode(value))
        } catch {
            return Self.error(status: 500, code: "encoding_failed", message: error.localizedDescription)
        }
    }

    static func text(_ value: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: responseHeaders, body: Data(value.utf8))
    }

    static func error(status: Int, code: String, message: String, field: String? = nil, requestID: String = UUID().uuidString) -> HTTPResponse {
        json(APIErrorEnvelope(error: .init(code: code, message: message, field: field, requestID: requestID)), status: status)
    }
}

final class HTTPServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "com.jakemawson.launchstation.http", qos: .userInitiated)
    private let handler: Handler
    private let token: String
    private var listener: NWListener?
    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 1 * 1024 * 1024

    init(token: String, handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    func start(port requestedPort: UInt16 = 0) async throws -> UInt16 {
        let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? requestedPort)
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "::1" || value == "localhost" || value.hasPrefix("127.")
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            if next.count > self.maxHeaderBytes + self.maxBodyBytes {
                self.send(.error(status: 413, code: "request_too_large", message: "Request exceeds the 1 MiB body limit."), to: connection)
                return
            }
            do {
                if let request = try self.parseIfComplete(next) {
                    guard self.isAuthorized(request) else {
                        self.send(.error(status: 401, code: "unauthorized", message: "A valid local launcher bearer token is required.", requestID: request.requestID), to: connection)
                        return
                    }
                    Task {
                        let response = await self.handler(request)
                        self.send(response, to: connection)
                    }
                    return
                }
            } catch let failure as HTTPParseFailure {
                self.send(.error(status: failure.status, code: failure.code, message: failure.message), to: connection)
                return
            } catch {
                self.send(.error(status: 400, code: "malformed_request", message: error.localizedDescription), to: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    private func parseIfComplete(_ data: Data) throws -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes { throw HTTPParseFailure(status: 431, code: "headers_too_large", message: "Request headers exceed 16 KiB.") }
            return nil
        }
        guard separator.lowerBound <= maxHeaderBytes else {
            throw HTTPParseFailure(status: 431, code: "headers_too_large", message: "Request headers exceed 16 KiB.")
        }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseFailure(status: 400, code: "invalid_headers", message: "Request headers must be UTF-8.")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseFailure(status: 400, code: "missing_request_line", message: "Request line is missing.") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw HTTPParseFailure(status: 400, code: "invalid_request_line", message: "Request line is invalid.") }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        guard ["GET", "POST", "PATCH", "DELETE"].contains(method) else {
            throw HTTPParseFailure(status: 405, code: "method_not_allowed", message: "HTTP method is not supported.")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseFailure(status: 400, code: "invalid_header", message: "A request header is malformed.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { throw HTTPParseFailure(status: 400, code: "invalid_content_length", message: "Content-Length is invalid.") }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBodyBytes else { throw HTTPParseFailure(status: 413, code: "request_too_large", message: "Request exceeds the 1 MiB body limit.") }
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(
            method: method,
            target: target,
            path: path,
            query: query,
            headers: headers,
            body: body,
            requestID: headers["x-request-id"] ?? UUID().uuidString
        )
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        request.headers["authorization"] == "Bearer \(token)"
    }

    private func send(_ response: HTTPResponse, to connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        var responseText = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        for key in headers.keys.sorted() {
            responseText += "\(key): \(headers[key]!)\r\n"
        }
        responseText += "\r\n"
        var data = Data(responseText.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 412: return "Precondition Failed"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Content"
        case 423: return "Locked"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private struct HTTPParseFailure: Error {
    var status: Int
    var code: String
    var message: String
}
