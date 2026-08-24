import Foundation

enum SyncAPIError: LocalizedError {
    case invalidURL
    case insecureURL
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .insecureURL: return "公网同步地址必须使用 HTTPS"
        case let .server(code, message): return "服务器返回 \(code)：\(message)"
        }
    }
}

struct SyncAPI {
    func upload(_ workouts: [WorkoutPayload], baseURL: String, token: String) async throws -> SyncResponse {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil else { throw SyncAPIError.invalidURL }
        let isLocal = components.host == "127.0.0.1" || components.host == "localhost"
        guard components.scheme == "https" || isLocal else { throw SyncAPIError.insecureURL }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "api/sync/apple-workouts"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else { throw SyncAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(SyncRequest(workouts: workouts))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncAPIError.server(0, "无响应") }
        guard 200..<300 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "未知错误"
            throw SyncAPIError.server(http.statusCode, message)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncResponse.self, from: data)
    }
}
