//  Typed wrappers over the CloudConvert v2 JSON endpoints (or your proxy's
//  mirror of them). Every call is authenticated, retried according to the
//  configured policy, and decoded into the `CC*` models.
//
//  The engine only needs `createJob` / `getJob` / `deleteJob`; the rest is
//  surfaced so apps can show the credit balance, validate a format pair or
//  inspect jobs without reaching around the kit.
//

import Foundation

public protocol CloudConvertAPIClient: Sendable {
    // Jobs
    func createJob(_ specification: JobSpecification) async throws -> CCJob
    func getJob(id: String) async throws -> CCJob
    func listJobs(_ filter: JobsFilter) async throws -> CCPage<CCJob>
    /// Best effort; a 404 (already purged) is treated as success.
    func deleteJob(id: String) async throws

    // Tasks
    func getTask(id: String) async throws -> CCTask
    func retryTask(id: String) async throws -> CCTask
    func cancelTask(id: String) async throws -> CCTask
    func deleteTask(id: String) async throws

    // Catalogue & account
    /// `GET /operations` – every operation, optionally filtered.
    func operations(filter: OperationsFilter) async throws -> [CCOperation]
    /// `GET /convert/formats` – supported conversion pairs (with `include=options`).
    func convertFormats(filter: OperationsFilter) async throws -> [CCOperation]
    /// `GET /users/me` – needs the `user.read` scope; returns the credit balance.
    func currentUser() async throws -> CCUser
}

public struct OperationsFilter: Equatable, Sendable {
    public var operation: String?
    public var inputFormat: String?
    public var outputFormat: String?
    public var engine: String?
    public var includeOptions: Bool
    public var alternatives: Bool

    public init(operation: String? = nil, inputFormat: String? = nil, outputFormat: String? = nil,
                engine: String? = nil, includeOptions: Bool = false, alternatives: Bool = false) {
        self.operation = operation
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.engine = engine
        self.includeOptions = includeOptions
        self.alternatives = alternatives
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let operation { items.append(URLQueryItem(name: "filter[operation]", value: operation)) }
        if let inputFormat { items.append(URLQueryItem(name: "filter[input_format]", value: inputFormat)) }
        if let outputFormat { items.append(URLQueryItem(name: "filter[output_format]", value: outputFormat)) }
        if let engine { items.append(URLQueryItem(name: "filter[engine]", value: engine)) }
        if includeOptions { items.append(URLQueryItem(name: "include", value: "options")) }
        if alternatives { items.append(URLQueryItem(name: "alternatives", value: "true")) }
        return items
    }
}

public struct JobsFilter: Equatable, Sendable {
    public var status: CCStatus?
    public var tag: String?
    /// Include each job's `tasks` array in the listing.
    public var includeTasks: Bool
    public var page: Int?
    public var perPage: Int?

    public init(status: CCStatus? = nil, tag: String? = nil, includeTasks: Bool = false, page: Int? = nil, perPage: Int? = nil) {
        self.status = status
        self.tag = tag
        self.includeTasks = includeTasks
        self.page = page
        self.perPage = perPage
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "filter[status]", value: status.rawValue)) }
        if let tag { items.append(URLQueryItem(name: "filter[tag]", value: tag)) }
        if includeTasks { items.append(URLQueryItem(name: "include", value: "tasks")) }
        if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
        if let perPage { items.append(URLQueryItem(name: "per_page", value: String(perPage))) }
        return items
    }
}

public final class CloudConvertAPI: CloudConvertAPIClient, @unchecked Sendable {

    private let baseURL: URL
    private let authorization: any AuthorizationProvider
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let logger: any CloudConvertLogging
    private let connectivity: any ConnectivityMonitoring
    private let offlineWaitTimeout: TimeInterval
    private let decoder = CCDateDecoding.makeDecoder()
    private let encoder = JSONEncoder()

    public init(configuration: CloudConvertConfiguration,
                transport: (any HTTPTransport)? = nil,
                connectivity: any ConnectivityMonitoring = ConnectivityMonitor.shared) {
        self.baseURL = configuration.environment.baseURL
        self.authorization = configuration.authorizationProvider
        self.transport = transport ?? URLSessionTransport(requestTimeout: configuration.apiRequestTimeout)
        self.retryPolicy = configuration.apiRetryPolicy
        self.logger = configuration.logger
        self.connectivity = connectivity
        self.offlineWaitTimeout = configuration.offlineWaitTimeout
    }

    // MARK: Jobs

    public func createJob(_ specification: JobSpecification) async throws -> CCJob {
        try specification.validate()
        let body = try encoder.encode(specification.requestBody)
        let envelope: CCDataEnvelope<CCJob> = try await send(method: "POST", path: "jobs", body: body, phase: .creatingJob, label: "createJob")
        return envelope.data
    }

    public func getJob(id: String) async throws -> CCJob {
        let envelope: CCDataEnvelope<CCJob> = try await send(method: "GET", path: "jobs/\(id)", phase: .processing, label: "getJob")
        return envelope.data
    }

    public func listJobs(_ filter: JobsFilter = JobsFilter()) async throws -> CCPage<CCJob> {
        try await send(method: "GET", path: "jobs", query: filter.queryItems, phase: .preparing, label: "listJobs")
    }

    public func deleteJob(id: String) async throws {
        do {
            _ = try await sendRaw(method: "DELETE", path: "jobs/\(id)", body: nil, phase: .finishing, label: "deleteJob", policy: .disabled)
        } catch CloudConvertError.notFound {
            return
        }
    }

    // MARK: Tasks

    public func getTask(id: String) async throws -> CCTask {
        let envelope: CCDataEnvelope<CCTask> = try await send(method: "GET", path: "tasks/\(id)", phase: .processing, label: "getTask")
        return envelope.data
    }

    public func retryTask(id: String) async throws -> CCTask {
        let envelope: CCDataEnvelope<CCTask> = try await send(method: "POST", path: "tasks/\(id)/retry", phase: .processing, label: "retryTask")
        return envelope.data
    }

    public func cancelTask(id: String) async throws -> CCTask {
        let envelope: CCDataEnvelope<CCTask> = try await send(method: "POST", path: "tasks/\(id)/cancel", phase: .processing, label: "cancelTask")
        return envelope.data
    }

    public func deleteTask(id: String) async throws {
        do {
            _ = try await sendRaw(method: "DELETE", path: "tasks/\(id)", body: nil, phase: .finishing, label: "deleteTask", policy: .disabled)
        } catch CloudConvertError.notFound {
            return
        }
    }

    // MARK: Catalogue & account

    public func operations(filter: OperationsFilter = OperationsFilter()) async throws -> [CCOperation] {
        let envelope: CCDataEnvelope<[CCOperation]> = try await send(method: "GET", path: "operations", query: filter.queryItems, phase: .preparing, label: "operations")
        return envelope.data
    }

    public func convertFormats(filter: OperationsFilter = OperationsFilter()) async throws -> [CCOperation] {
        let envelope: CCDataEnvelope<[CCOperation]> = try await send(method: "GET", path: "convert/formats", query: filter.queryItems, phase: .preparing, label: "convertFormats")
        return envelope.data
    }

    public func currentUser() async throws -> CCUser {
        let envelope: CCDataEnvelope<CCUser> = try await send(method: "GET", path: "users/me", phase: .preparing, label: "currentUser")
        return envelope.data
    }

    // MARK: Plumbing

    private func send<T: Decodable>(method: String,
                                    path: String,
                                    query: [URLQueryItem] = [],
                                    body: Data? = nil,
                                    phase: ConversionPhase,
                                    label: String) async throws -> T {
        let response = try await sendRaw(method: method, path: path, query: query, body: body, phase: phase, label: label, policy: retryPolicy)
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            let snippet = String(data: response.body.prefix(300), encoding: .utf8) ?? "<binary>"
            logger.error("\(label): could not decode response: \(error) body=\(snippet)")
            throw CloudConvertError.decoding(reason: "\(label): \(error)")
        }
    }

    @discardableResult
    private func sendRaw(method: String,
                         path: String,
                         query: [URLQueryItem] = [],
                         body: Data?,
                         phase: ConversionPhase,
                         label: String,
                         policy: RetryPolicy) async throws -> HTTPResponse {
        let connectivity = self.connectivity
        let offlineWaitTimeout = self.offlineWaitTimeout
        return try await retrying(policy: policy, phase: phase, logger: logger, label: label,
                                  waitForNetwork: { try await connectivity.waitUntilConnected(timeout: offlineWaitTimeout) },
                                  operation: {
            try await self.performOnce(method: method, path: path, query: query, body: body, label: label)
        })
    }

    /// One HTTP round trip with a single transparent re-auth on 401.
    private func performOnce(method: String, path: String, query: [URLQueryItem], body: Data?, label: String) async throws -> HTTPResponse {
        let connected = await connectivity.isConnected
        if !connected {
            throw CloudConvertError.notConnected
        }
        var request = try await makeRequest(method: method, path: path, query: query, body: body)
        var response = try await transport.send(request)
        logger.debug("\(label): \(method) /\(path) → \(response.status)", metadata: response.rateLimitRemaining.map { ["rateLimitRemaining": String($0)] } ?? [:])

        if response.status == 401, await authorization.handleUnauthorized() {
            request = try await makeRequest(method: method, path: path, query: query, body: body)
            response = try await transport.send(request)
        }

        guard response.isSuccess else {
            throw HTTPErrorMapper.error(for: response)
        }
        return response
    }

    private func makeRequest(method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw CloudConvertError.invalidRequest(reason: "Invalid base URL")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw CloudConvertError.invalidRequest(reason: "Invalid request URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let auth = try await authorization.authorizationHeaderValue() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in try await authorization.additionalHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(CloudConvertAPI.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static let userAgent: String = {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #elseif os(visionOS)
        let platform = "visionOS"
        #else
        let platform = "Apple"
        #endif
        return "\(name)/\(version) CloudConvertKit/1.0 (\(platform))"
    }()
}
