import Foundation

// MARK: - Usage API Service

actor UsageAPIService {
    static let shared = UsageAPIService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Fetch Usage

    /// Fetch current usage data from the API
    func fetchUsage(token: String) async throws -> UsageResponse {
        guard let url = URL(string: Constants.API.usageEndpoint) else {
            throw UsageAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Constants.Headers.anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Constants.Headers.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageAPIError.invalidResponse
        }

        // Handle different status codes
        switch httpResponse.statusCode {
        case 200:
            break // Success, continue parsing
        case 401:
            throw UsageAPIError.invalidToken
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            let message = String(data: data, encoding: .utf8)
            throw UsageAPIError.serverError(statusCode: httpResponse.statusCode, message: message)
        default:
            let message = String(data: data, encoding: .utf8)
            throw UsageAPIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        // Parse response
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decodingError(error)
        }
    }
}

// MARK: - Usage API Service Protocol (for testing)

protocol UsageAPIServiceProtocol {
    func fetchUsage(token: String) async throws -> UsageResponse
}

extension UsageAPIService: UsageAPIServiceProtocol {}

// MARK: - Mock Service (for testing/preview)

#if DEBUG
actor MockUsageAPIService: UsageAPIServiceProtocol {
    var mockResponse: UsageResponse?
    var mockError: UsageAPIError?

    func fetchUsage(token: String) async throws -> UsageResponse {
        if let error = mockError {
            throw error
        }

        if let response = mockResponse {
            return response
        }

        // Return sample data
        return UsageResponse(
            fiveHour: UsageMetric(
                utilization: 32.0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 + 11 * 60))
            ),
            sevenDay: UsageMetric(
                utilization: 5.0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 24 * 3600))
            ),
            sevenDayOpus: UsageMetric(
                utilization: 0.0,
                resetsAt: nil
            ),
            sevenDaySonnet: UsageMetric(
                utilization: 12.0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 24 * 3600))
            ),
            sevenDayOauthApps: nil,
            iguanaNecktie: nil
        )
    }
}
#endif
