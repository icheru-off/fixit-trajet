import Foundation

/// File d'attente persistante des positions GPS.
/// Chaque position est écrite sur le disque de l'iPhone avant l'envoi : rien n'est perdu
/// dans une zone sans 4G/5G, même si l'app est fermée ou l'iPhone redémarré.
actor PointQueue {
    private var points: [TrackPoint] = []
    private let url: URL
    private let maxPoints = 3000   // ≈ 4 h de trajet à 1 point / 5 s

    init(tripId: Int) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("queue-\(tripId).json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([TrackPoint].self, from: data) {
            points = saved
        }
    }

    var count: Int { points.count }
    var last: TrackPoint? { points.last }

    func append(_ p: TrackPoint) {
        points.append(p)
        if points.count > maxPoints {
            // on garde le début du trajet et la fin la plus récente, on allège le milieu
            points = Array(points.prefix(200)) + Array(points.suffix(maxPoints - 400))
        }
        persist()
    }

    func peek(_ n: Int) -> [TrackPoint] { Array(points.prefix(n)) }

    func drop(_ n: Int) {
        points.removeFirst(min(n, points.count))
        persist()
    }

    func clear() {
        points.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
