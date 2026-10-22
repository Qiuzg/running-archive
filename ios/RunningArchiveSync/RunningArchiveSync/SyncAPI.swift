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
    static func endpoint(baseURL: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw SyncAPIError.invalidURL }
        let isLocal = components.host == "127.0.0.1" || components.host == "localhost"
        guard components.scheme == "https" || (components.scheme == "http" && isLocal) else { throw SyncAPIError.insecureURL }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "api/sync/apple-workouts"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else { throw SyncAPIError.invalidURL }

        return url
    }

    func upload(_ workouts: [WorkoutPayload], baseURL: String, token: String) async throws -> SyncResponse {
        var request = URLRequest(url: try Self.endpoint(baseURL: baseURL))
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
            let message = serverErrorMessage(from: data)
            throw SyncAPIError.server(http.statusCode, message)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncResponse.self, from: data)
    }

    private func serverErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           let detail = dictionary["detail"] {
            if let message = detail as? String {
                return message
            }
            if JSONSerialization.isValidJSONObject(detail),
               let detailData = try? JSONSerialization.data(withJSONObject: detail),
               let message = String(data: detailData, encoding: .utf8) {
                return message
            }
        }

        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }
        return "未知错误"
    }
}
