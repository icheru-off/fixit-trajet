import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case auth
    case http(Int)
    case network(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "L'application n'est pas encore configurée."
        case .auth: return "Clé refusée par le serveur. Reconfigurez l'app depuis Réglages du site."
        case .http(let c): return "Erreur serveur (\(c))."
        case .network(let m): return "Pas de connexion : \(m)"
        case .decoding: return "Réponse inattendue du serveur."
        }
    }
}

/// Client de l'API du site (api/app.php). Requêtes courtes, compressées, sans cache.
final class APIClient {
    let base: URL
    let key: String
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(base: URL, key: String) {
        self.base = base
        self.key = key
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        c.waitsForConnectivity = false        // la file d'attente gère elle-même les nouvelles tentatives
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 2
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true // mode « données réduites » : on envoie quand même (requêtes minuscules)
        session = URLSession(configuration: c)
    }

    private func request<T: Decodable>(_ body: [String: Any], as type: T.Type) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent("api/app.php"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-App-Key")
        req.setValue("FixIT-Trajet-iOS/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("réponse vide") }
        if http.statusCode == 401 { throw APIError.auth }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    func ping() async throws -> PingResponse {
        try await request(["action": "ping"], as: PingResponse.self)
    }

    func list() async throws -> [Intervention] {
        try await request(["action": "list"], as: ListResponse.self).items
    }

    func depart(id: Int, lat: Double?, lon: Double?) async throws -> StateResponse {
        var b: [String: Any] = ["action": "depart", "id": id]
        if let lat, let lon { b["lat"] = lat; b["lon"] = lon }
        return try await request(b, as: StateResponse.self)
    }

    func sendPoints(id: Int, points: [TrackPoint], knownRoute: Int) async throws -> StateResponse {
        try await request(["action": "points", "id": id, "v": knownRoute, "points": points.map(\.json)], as: StateResponse.self)
    }

    func arrived(id: Int) async throws -> StateResponse {
        try await request(["action": "arrived", "id": id, "v": -1], as: StateResponse.self)
    }

    func stop(id: Int) async throws -> StateResponse {
        try await request(["action": "stop", "id": id, "v": -1], as: StateResponse.self)
    }

    func state(id: Int) async throws -> StateResponse {
        try await request(["action": "state", "id": id, "v": -1], as: StateResponse.self)
    }
}
