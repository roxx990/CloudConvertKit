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

    /// Called once after a 401, with the `Authorization` value that was
    /// refused. Return `true` if credentials were refreshed (or another
    /// request already refreshed them) and the request should be sent again,
    /// `false` to fail with `.unauthorized`.
    ///
    /// A failure to supply credentials, from this or from
    /// `authorizationHeaderValue`, reaches the app as
    /// `CloudConvertError.authorizationFailed`, which is not retried; throw a
    /// `CloudConvertError` (`.notConnected`, say) to report something else.
    func handleUnauthorized(rejected: String?) async -> Bool
}

public extension AuthorizationProvider {
    func additionalHeaders() async throws -> [String: String] { [:] }
    func handleUnauthorized(rejected: String?) async -> Bool { false }
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

/// Fetches a bearer credential on demand and caches it until a 401
/// invalidates it. Works for a proxy token as well as for a CloudConvert API
/// key kept in a remote config store (Firebase Realtime Database, Remote
/// Config…): CloudConvert authenticates API keys with the same
/// `Authorization: Bearer <key>` header, and a 401 after the key was rotated
/// triggers exactly one re-fetch.
///
/// - Requests that need the credential at the same time share one fetch.
/// - A 401 drops the credential only if it is the one that was refused, so
///   several requests refused together re-fetch once.
/// - A failed fetch is reported again, without fetching, for
///   `failureCooldown` seconds: conversions started together don't each hit
///   the store while it is down.
public actor RefreshableTokenAuthorization: AuthorizationProvider {

    public typealias TokenFetcher = @Sendable () async throws -> String

    private let fetcher: TokenFetcher
    private let extraHeaders: [String: String]
    private let failureCooldown: TimeInterval
    private var cachedToken: String?
    private var inFlight: Task<String, Error>?
    private var lastFailure: (error: Error, at: Date)?

    public init(extraHeaders: [String: String] = [:],
                failureCooldown: TimeInterval = 10,
                fetcher: @escaping TokenFetcher) {
        self.fetcher = fetcher
        self.extraHeaders = extraHeaders
        self.failureCooldown = failureCooldown
    }

    public func authorizationHeaderValue() async throws -> String? {
        "Bearer \(try await token())"
    }

    public func additionalHeaders() async throws -> [String: String] { extraHeaders }

    public func handleUnauthorized(rejected: String?) async -> Bool {
        // Refused with a credential that has been replaced since: just retry.
        if let rejected, let cachedToken, rejected != "Bearer \(cachedToken)" { return true }
        cachedToken = nil
        lastFailure = nil
        return true
    }

    private func token() async throws -> String {
        if let cachedToken { return cachedToken }
        if let lastFailure, Date().timeIntervalSince(lastFailure.at) < failureCooldown { throw lastFailure.error }
        if let inFlight { return try await inFlight.value }

        let fetch = Task { [fetcher] in
            let token = try await fetcher()
            guard !token.isEmpty else {
                throw CloudConvertError.authorizationFailed(underlying: "The token fetcher returned an empty credential")
            }
            return token
        }
        inFlight = fetch
        do {
            let token = try await fetch.value
            inFlight = nil
            cachedToken = token
            return token
        } catch {
            inFlight = nil
            // A cancelled caller says nothing about the store.
            if !(error is CancellationError) { lastFailure = (error, Date()) }
            throw error
        }
    }
}
