import Foundation

final class BeszelAPIService: @unchecked Sendable {
    private let instance: Instance
    private var authToken: String?
    private let lock = NSLock()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(instance: Instance) {
        self.instance = instance
    }

    private func getValidToken() async throws -> String {
        if let currentToken = authToken {
            return currentToken
        }

        let cred = instance.credential
        guard !cred.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        if isJWT(cred) {
            return try await refreshToken(currentToken: cred)
        } else {
            return try await loginWithPassword(password: cred)
        }
    }

    private func isJWT(_ str: String) -> Bool {
        let parts = str.components(separatedBy: ".")
        return parts.count == 3 && str.hasPrefix("ey")
    }

    private func loginWithPassword(password: String) async throws -> String {
        guard let url = URL(string: "\(instance.url)/api/collections/users/auth-with-password") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["identity": instance.email, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }

        let authResponse = try jsonDecoder.decode(AuthResponse.self, from: data)
        lock.lock()
        self.authToken = authResponse.token
        lock.unlock()
        return authResponse.token
    }

    private func refreshToken(currentToken: String) async throws -> String {
        guard let url = URL(string: "\(instance.url)/api/collections/users/auth-refresh") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }

        let authResponse = try jsonDecoder.decode(AuthResponse.self, from: data)
        lock.lock()
        self.authToken = authResponse.token
        lock.unlock()
        return authResponse.token
    }

    private func performRequest<T: Decodable>(with url: URL, retryCount: Int = 0) async throws -> T {
        let token = try await getValidToken()

        var request = URLRequest(url: url)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                return try jsonDecoder.decode(T.self, from: data)
            } else if httpResponse.statusCode == 401 && retryCount < 1 {
                lock.lock()
                authToken = nil
                lock.unlock()
                return try await performRequest(with: url, retryCount: retryCount + 1)
            } else {
                throw BeszelAPIError.httpError(statusCode: httpResponse.statusCode, url: url.absoluteString)
            }
        } else {
            throw URLError(.badServerResponse)
        }
    }

    func fetchSystems() async throws -> [SystemRecord] {
        try await fetchAllPages(path: "/api/collections/systems/records", filter: nil)
    }

    func fetchSystemDetails() async throws -> [SystemDetailsRecord] {
        guard let url = URL(string: "\(instance.url)/api/collections/system_details/records") else {
            throw URLError(.badURL)
        }

        do {
            let response: PocketBaseListResponse<SystemDetailsRecord> = try await performRequest(with: url)
            return response.items
        } catch let error as BeszelAPIError {
            if case .httpError(let statusCode, _) = error, statusCode == 404 {
                return []
            }
            throw error
        }
    }

    func fetchSystemStats(systemID: String, limit: Int = 1) async throws -> [SystemStatsRecord] {
        guard var components = URLComponents(string: instance.url) else {
            throw URLError(.badURL)
        }
        components.path = "/api/collections/system_stats/records"
        components.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "-created"),
            URLQueryItem(name: "filter", value: "system = '\(systemID)'")
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let response: PocketBaseListResponse<SystemStatsRecord> = try await performRequest(with: url)
        return response.items
    }

    /// Fetches the most recent stats record per system in batched requests.
    /// Used for per-GPU metrics (utilization, VRAM, power, temperature) which
    /// only exist on `system_stats`, not on the live `info` blob.
    /// PocketBase caps filter strings at 3500 chars, so large hubs are chunked.
    func fetchLatestSystemStats(for systemIDs: [String]) async throws -> [String: SystemStatsRecord] {
        guard !systemIDs.isEmpty else { return [:] }

        var latestPerSystem: [String: SystemStatsRecord] = [:]
        for chunk in systemIDs.chunked(into: 50) {
            let chunkResult = try await fetchLatestSystemStatsChunk(for: chunk)
            for (systemID, record) in chunkResult {
                latestPerSystem[systemID] = record
            }
        }
        return latestPerSystem
    }

    private func fetchLatestSystemStatsChunk(for systemIDs: [String]) async throws -> [String: SystemStatsRecord] {
        guard var components = URLComponents(string: instance.url) else {
            throw URLError(.badURL)
        }

        let filter = systemIDs.map { "system = '\($0)'" }.joined(separator: " || ")
        components.path = "/api/collections/system_stats/records"
        components.queryItems = [
            URLQueryItem(name: "perPage", value: String(max(systemIDs.count * 4, 12))),
            URLQueryItem(name: "sort", value: "-created"),
            URLQueryItem(name: "filter", value: "(\(filter))")
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let response: PocketBaseListResponse<SystemStatsRecord> = try await performRequest(with: url)

        var latestPerSystem: [String: SystemStatsRecord] = [:]
        for record in response.items {
            guard let systemID = record.system, latestPerSystem[systemID] == nil else { continue }
            latestPerSystem[systemID] = record
        }
        return latestPerSystem
    }

    func fetchAlerts(filter: String? = nil) async throws -> [AlertRecord] {
        try await fetchAllPages(path: "/api/collections/alerts/records", filter: filter)
    }

    func fetchLatestAlerts(limit: Int = 10) async throws -> [AlertRecord] {
        guard var components = URLComponents(string: instance.url) else {
            throw URLError(.badURL)
        }
        components.path = "/api/collections/alerts/records"
        components.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "-created")
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let response: PocketBaseListResponse<AlertRecord> = try await performRequest(with: url)
        return response.items
    }

    func fetchContainers(filter: String? = nil) async throws -> [ContainerRecord] {
        do {
            return try await fetchAllPages(path: "/api/collections/containers/records", filter: filter)
        } catch let error as BeszelAPIError {
            if case .httpError(let statusCode, _) = error, statusCode == 404 {
                return [] // Containers collection doesn't exist
            }
            throw error
        }
    }

    func fetchContainers(for systemID: String) async throws -> [ContainerRecord] {
        try await fetchContainers(filter: "system = '\(systemID)'")
    }

    func fetchContainerStats(systemID: String, limit: Int = 1) async throws -> [ContainerStatsRecord] {
        guard var components = URLComponents(string: instance.url) else {
            throw URLError(.badURL)
        }
        components.path = "/api/collections/container_stats/records"
        components.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit * 100)), // Get latest for multiple containers
            URLQueryItem(name: "sort", value: "-created"),
            URLQueryItem(name: "filter", value: "system = '\(systemID)'")
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        do {
            let response: PocketBaseListResponse<ContainerStatsRecord> = try await performRequest(with: url)

            var latestPerContainer: [String: ContainerStatsRecord] = [:]
            for stat in response.items {
                if latestPerContainer[stat.containerID] == nil {
                    latestPerContainer[stat.containerID] = stat
                }
            }
            return Array(latestPerContainer.values)
        } catch let error as BeszelAPIError {
            if case .httpError(let statusCode, _) = error, statusCode == 404 {
                return []
            }
            throw error
        }
    }

    private func fetchAllPages<T: Codable>(path: String, filter: String?) async throws -> [T] {
        var allItems: [T] = []
        var currentPage = 1
        var totalPages = 1

        repeat {
            let url = try buildURL(for: path, filter: filter, page: currentPage)
            let response: PocketBaseListResponse<T> = try await performRequest(with: url)

            allItems.append(contentsOf: response.items)
            totalPages = response.totalPages
            currentPage += 1
        } while currentPage <= totalPages

        return allItems
    }

    private func buildURL(for path: String, filter: String?, page: Int = 1) throws -> URL {
        guard var components = URLComponents(string: instance.url) else {
            throw URLError(.badURL)
        }

        components.path = path
        components.queryItems = [
            URLQueryItem(name: "perPage", value: "500"),
            URLQueryItem(name: "page", value: String(page))
        ]

        if let filter = filter {
            components.queryItems?.append(URLQueryItem(name: "filter", value: filter))
        }

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        return url
    }
}

enum BeszelAPIError: LocalizedError {
    case httpError(statusCode: Int, url: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let url):
            return "HTTP \(statusCode) error for \(url)"
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

