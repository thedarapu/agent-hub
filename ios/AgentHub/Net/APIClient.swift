import Foundation

struct APIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Thin HTTP client for the daemon. Every request carries the bearer token.
struct APIClient {
    var pairing: Pairing

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: pairing.baseURL, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return comps.url!
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: Encodable? = nil) -> URLRequest {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        r.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONEncoder().encode(AnyEncodable(body))
        }
        return r
    }

    func data(_ method: String, _ path: String, query: [String: String] = [:], body: Encodable? = nil) async throws -> Data {
        let (data, resp) = try await Self.session.data(for: request(method, path, query: query, body: body))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(status)"
            throw APIError(status: status, message: msg)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data("GET", path, query: query))
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(method, path, body: body))
    }

    func sendIgnoring(_ method: String, _ path: String, body: Encodable? = nil) async throws {
        _ = try await data(method, path, body: body)
    }

    /// Path-encodes a relative file path for /files and /vfiles.
    static func encodePath(_ rel: String) -> String {
        rel.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }.joined(separator: "/")
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
