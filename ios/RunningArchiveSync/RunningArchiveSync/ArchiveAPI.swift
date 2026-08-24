import Foundation

enum ArchiveAPIError: LocalizedError {
    case invalidURL
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case let .server(code): return "服务器返回 \(code)"
        }
    }
}

struct ArchiveAPI {
    static let defaultBaseURL = "https://123.56.181.123/run"

    func summary() async throws -> ArchiveSummary {
        try await request("api/stats/summary")
    }

    func routes() async throws -> [ArchiveRouteSummary] {
        try await request("api/routes")
    }

    func runs() async throws -> [ArchiveRun] {
        try await request("api/runs")
    }

    func races() async throws -> [ArchiveRace] {
        try await request("api/races")
    }

    func route(id: String) async throws -> ArchiveRouteDetail {
        try await request("api/routes/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        let stored = UserDefaults.standard.string(forKey: "serverURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (stored?.isEmpty == false ? stored! : Self.defaultBaseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)") else { throw ArchiveAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ArchiveAPIError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .formatted(.archiveDay)
        return try decoder.decode(T.self, from: data)
    }
}
