import Foundation
import CoreLocation
import Network
import UIKit

/// Cœur de l'app : GPS natif en arrière-plan, file d'attente hors-ligne et envoi par lots.
@MainActor
final class TripManager: NSObject, ObservableObject {
    // État affiché
    @Published private(set) var trip: Intervention?
    @Published private(set) var state: TripState?
    @Published private(set) var route: [CLLocationCoordinate2D] = []
    @Published private(set) var location: CLLocation?
    @Published private(set) var speedKmh: Int?
    @Published private(set) var pending = 0
    @Published private(set) var online = true
    @Published private(set) var lastSync: Date?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published var message: String?
    @Published private(set) var busy = false

    var isTracking: Bool { trip != nil && state?.status == "enroute" }

    private let manager = CLLocationManager()
    private let monitor = NWPathMonitor()
    private var queue: PointQueue?
    private var config: AppConfig?
    private var routeV = -1
    private var uploading = false
    private var failCount = 0
    private var nextTry = Date.distantPast
    private var lastQueued: TrackPoint?
    private var timer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private static let activeKey = "activeTripId"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.online = path.status == .satisfied
                if self.online { self.nextTry = .distantPast; await self.flush() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "fixit.network"))
    }

    func attach(_ config: AppConfig) {
        self.config = config
    }

    // MARK: - Démarrage / reprise

    /// Reprend un trajet en cours si l'app a été relancée (iOS peut la relancer en arrière-plan).
    func resumeIfNeeded() async {
        let id = UserDefaults.standard.integer(forKey: Self.activeKey)
        guard id > 0, trip == nil, let api = config?.client else { return }
        do {
            let r = try await api.state(id: id)
            if r.state.status == "enroute", let item = r.item {
                trip = item
                apply(r.state)
                queue = PointQueue(tripId: id)
                pending = await queue?.count ?? 0
                startLocation()
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        } catch {
            // hors réseau : on reprend quand même le suivi local, l'envoi suivra
            message = "Trajet repris hors connexion."
        }
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func start(_ iv: Intervention) async {
        guard let api = config?.client else { return }
        busy = true
        defer { busy = false }
        requestPermission()
        manager.startUpdatingLocation()
        // attend une première position (10 s max) pour que l'itinéraire parte du bon endroit
        var waited = 0
        while (location == nil || (location?.timestamp.timeIntervalSinceNow ?? -999) < -30) && waited < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        let here = location
        do {
            let r = try await api.depart(id: iv.id, lat: here?.coordinate.latitude, lon: here?.coordinate.longitude)
            trip = r.item ?? iv
            routeV = -1
            apply(r.state)
            UserDefaults.standard.set(iv.id, forKey: Self.activeKey)
            let q = PointQueue(tripId: iv.id)
            await q.clear()
            queue = q
            lastQueued = nil
            if let here { await enqueue(here) }
            startLocation()
            message = nil
        } catch {
            manager.stopUpdatingLocation()
            message = error.localizedDescription
        }
    }

    private func startLocation() {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func stopLocation() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Fin de trajet

    func arrived() async {
        guard let trip, let api = config?.client else { return }
        await flush(force: true)
        do {
            let r = try await api.arrived(id: trip.id)
            apply(r.state)
        } catch {
            message = error.localizedDescription
            return
        }
        await finish()
    }

    func stop() async {
        guard let trip, let api = config?.client else { return }
        _ = try? await api.stop(id: trip.id)
        await finish()
    }

    private func finish() async {
        stopLocation()
        await queue?.clear()
        queue = nil
        pending = 0
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
    }

    func close() {
        trip = nil
        state = nil
        route = []
        routeV = -1
    }

    // MARK: - File d'attente & envoi

    private func enqueue(_ loc: CLLocation) async {
        guard let queue else { return }
        let p = TrackPoint(
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            acc: max(0, loc.horizontalAccuracy),
            speed: loc.speed >= 0 ? loc.speed : nil,
            heading: loc.course >= 0 ? loc.course : nil,
            ts: Int(loc.timestamp.timeIntervalSince1970)
        )
        // on évite les doublons inutiles : 1 point tous les 15 m ou toutes les 5 s
        if let last = lastQueued {
            let d = p.location.distance(from: last.location)
            if d < 15 && p.ts - last.ts < 5 { return }
        }
        lastQueued = p
        await queue.append(p)
        pending = await queue.count
    }

    /// Toutes les 4 s : envoi + « battement » à l'arrêt (bouchon) pour que le serveur constate le ralentissement.
    private func tick() async {
        guard isTracking else { return }
        if let last = lastQueued, Int(Date().timeIntervalSince1970) - last.ts > 15 {
            let p = TrackPoint(lat: last.lat, lon: last.lon, acc: last.acc, speed: 0, heading: last.heading, ts: Int(Date().timeIntervalSince1970))
            lastQueued = p
            await queue?.append(p)
            pending = await queue?.count ?? 0
        }
        await flush()
    }

    func flush(force: Bool = false) async {
        guard let trip, let queue, let api = config?.client, !uploading else { return }
        if !force && Date() < nextTry { return }
        let batch = await queue.peek(150)
        guard !batch.isEmpty else { return }
        uploading = true
        beginBackgroundTask()
        defer { uploading = false; endBackgroundTask() }
        do {
            let r = try await api.sendPoints(id: trip.id, points: batch, knownRoute: routeV)
            await queue.drop(batch.count)
            pending = await queue.count
            failCount = 0
            nextTry = .distantPast
            lastSync = Date()
            apply(r.state)
            if r.state.status != "enroute" {
                await finish()
                message = r.state.status == "arrived" ? "Arrivée détectée automatiquement ✅" : nil
            } else if pending > 0 {
                Task { await self.flush(force: true) }   // vide le reste du retard d'un coup
            }
        } catch APIError.auth {
            message = APIError.auth.errorDescription
        } catch {
            failCount += 1
            let delay = min(30.0, 2.0 * pow(2.0, Double(failCount - 1)))
            nextTry = Date().addingTimeInterval(delay)
        }
    }

    private func apply(_ s: TripState) {
        state = s
        if let r = s.route {
            routeV = s.routeV
            route = r.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        }
    }

    private func beginBackgroundTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "fixit-upload") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Messages

    func enrouteMessage() -> String? {
        guard let trip else { return nil }
        let when = state?.eta.map { Fmt.clockRoundedUp($0.at) } ?? "dès que possible"
        return trip.msgEnroute.replacingOccurrences(of: "{eta}", with: when)
    }
}

extension TripManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for loc in locations {
                // positions trop imprécises ignorées (tunnels, immeubles…)
                guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100 else { continue }
                self.location = loc
                if loc.speed >= 0 { self.speedKmh = Int((loc.speed * 3.6).rounded()) }
                if self.isTracking { await self.enqueue(loc) }
            }
            if self.isTracking, let s = self.lastSync, Date().timeIntervalSince(s) > 4 { await self.flush() }
            else if self.isTracking && self.lastSync == nil { await self.flush() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.allowsBackgroundLocationUpdates = true
                self.manager.showsBackgroundLocationIndicator = true
            }
            if status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if (error as? CLError)?.code == .denied {
                self.message = "Localisation refusée : Réglages › FixIT Trajet › Position › Toujours."
            }
        }
    }
}
