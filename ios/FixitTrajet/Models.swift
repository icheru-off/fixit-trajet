import Foundation
import CoreLocation

/// Intervention telle que renvoyée par api/app.php (action "list").
struct Intervention: Codable, Identifiable, Hashable {
    let id: Int
    let client: String
    let phone: String
    let address: String
    let addressExtra: String
    let lat: Double
    let lon: Double
    let scheduledAt: Int
    let status: String
    let statusLabel: String
    let link: String
    let msgEnroute: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var scheduledDate: Date { Date(timeIntervalSince1970: TimeInterval(scheduledAt)) }
}

struct ETA: Codable, Hashable {
    let at: Int
    let low: Int
    let high: Int
    let distM: Int
    let traffic: Bool
    let jam: Bool
}

struct TripState: Codable {
    let id: Int
    let status: String
    let now: Int
    let routeV: Int
    let eta: ETA?
    let provider: String?
    let speed: Double?
    let route: [[Double]]?
}

struct ListResponse: Codable {
    let ok: Bool
    let items: [Intervention]
}

struct StateResponse: Codable {
    let ok: Bool?
    let state: TripState
    let item: Intervention?
    let received: Int?
}

struct PingResponse: Codable {
    let ok: Bool
    let tech: String
}

/// Position GPS mise en file d'attente avant envoi.
struct TrackPoint: Codable, Equatable {
    let lat: Double
    let lon: Double
    let acc: Double
    let speed: Double?
    let heading: Double?
    let ts: Int

    var json: [String: Any] {
        var d: [String: Any] = ["lat": lat, "lon": lon, "acc": acc.rounded(), "ts": ts]
        if let speed { d["speed"] = (speed * 10).rounded() / 10 }
        if let heading { d["heading"] = heading.rounded() }
        return d
    }

    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

enum Fmt {
    static func clock(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "H'h'mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Heure arrondie aux 5 minutes supérieures (pour les messages au client).
    static func clockRoundedUp(_ ts: Int) -> String {
        clock(Int((Double(ts) / 300).rounded(.up)) * 300)
    }

    static func duration(_ seconds: Int) -> String {
        let m = max(1, Int((Double(seconds) / 60).rounded()))
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(String(format: "%02d", m % 60))"
    }

    static func distance(_ meters: Int) -> String {
        if meters < 1000 { return "\(meters / 10 * 10) m" }
        let km = Double(meters) / 1000
        return String(format: km < 10 ? "%.1f km" : "%.0f km", km).replacingOccurrences(of: ".", with: ",")
    }

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInTomorrow(date) { return "Demain" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: date).capitalized
    }
}
