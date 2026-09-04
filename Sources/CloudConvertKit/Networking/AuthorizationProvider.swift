//  Abstracts where credentials come from so the kit works unchanged whether
//  it talks to CloudConvert directly (API key) or to your own proxy (app
//  token, Firebase App Check, signed request…).
//

import Foundation

public protocol AuthorizationProvider: Sendable {
    /// Value for the `Authorization` header, e.g. `"Bearer …"`. Return `nil`
    /// to send no header (a proxy that authenticates by other means).
    func authorizationHeaderValue() async throws -> String?

    /// Extra headers to attach to every API request (App Check tokens,
    /// app version, device id…). Defaults to none.
    func additionalHeaders() async throws -> [String: String]

    /// Called once after a 401. Return `true` if credentials were refreshed
    /// and the request should be retried, `false` to fail immediately.
    func handleUnauthorized() async -> Bool
}

public extension AuthorizationProvider {
    func additionalHeaders() async throws -> [String: String] { [:] }
    func handleUnauthorized() async -> Bool { false }
}

/// Direct CloudConvert access with a static API key.
public struct StaticAPIKeyAuthorization: AuthorizationProvider {
    private let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }
    public func authorizationHeaderValue() async throws -> String? { "Bearer \(apiKey)" }
}

/// No `Authorization` header at all (proxy authenticates another way, or not at all).
public struct NoAuthorization: AuthorizationProvider {
    public init() {}
    public func authorizationHeaderValue() async throws -> String? { nil }
}

/// Fetches a bearer credential on demand and caches it until
/// `handleUnauthorized` invalidates it. Works for a proxy token as well as
/// for a CloudConvert API key kept in a remote config store (Firebase
/// Realtime Database, Remote Config…): CloudConvert authenticates API keys
/// with the same `Authorization: Bearer <key>` header, and a 401 after the
/// key was rotated triggers exactly one re-fetch.
public actor RefreshableTokenAuthorization: AuthorizationProvider {

    public typealias TokenFetcher = @Sendable () async throws -> String

    private let fetcher: TokenFetcher
    private let extraHeaders: [String: String]
    private var cachedToken: String?

    public init(extraHeaders: [String: String] = [:], fetcher: @escaping TokenFetcher) {
        self.fetcher = fetcher
        self.extraHeaders = extraHeaders
    }

    public func authorizationHeaderValue() async throws -> String? {
        if let cachedToken { return "Bearer \(cachedToken)" }
        let token = try await fetcher()
        cachedToken = token
        return "Bearer \(token)"
    }

    public func additionalHeaders() async throws -> [String: String] { extraHeaders }

    public func handleUnauthorized() async -> Bool {
        cachedToken = nil
        return true
    }
}
