//  Thin transport for JSON API calls. Everything that is not "send bytes,
//  get bytes" (auth, retries, decoding, error mapping) lives one layer up in
//  `CloudConvertAPI`, so the transport can be swapped for a stub in tests.
//

import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Parses `Retry-After` (delta-seconds or HTTP-date).
    public var retryAfter: TimeInterval? {
        guard let raw = header("Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    public var rateLimitRemaining: Int? {
        header("X-RateLimit-Remaining").flatMap { Int($0) }
    }

    public var isSuccess: Bool { (200...299).contains(status) }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed transport for short JSON requests (never used for
/// file transfers — those go through `BackgroundTransferManager`).
public final class URLSessionTransport: HTTPTransport {

    private let session: URLSession

    public init(requestTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false   // the engine handles offline explicitly
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudConvertError.invalidResponse(reason: "Non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

// MARK: - Error mapping

enum HTTPErrorMapper {

    /// Turns a non-2xx response into the matching `CloudConvertError`.
    static func error(for response: HTTPResponse) -> CloudConvertError {
        let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: response.body)
        switch response.status {
        case 401: return .unauthorized(payload)
        case 402: return .paymentRequired(payload)
        case 403: return .forbidden(payload)
        case 404: return .notFound(payload)
        case 422, 400: return .validation(payload)
        case 429: return .rateLimited(retryAfter: response.retryAfter)
        case 500...599: return .serverError(status: response.status, payload)
        default:
            let snippet = String(data: response.body.prefix(512), encoding: .utf8)
            return .unexpectedStatus(status: response.status, body: snippet)
        }
    }
}
