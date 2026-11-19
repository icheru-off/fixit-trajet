import SwiftUI
import UIKit
import MapKit

struct TripView: View {
    @EnvironmentObject var trips: TripManager
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                TripMap(route: trips.route, destination: trips.trip?.coordinate, follow: trips.isTracking)
                    .ignoresSafeArea(edges: .horizontal)
                if trips.isTracking { networkPill.padding(.top, 10) }
            }
            panel
        }
        .background(Brand.paper)
        .confirmationDialog("Arrêter le trajet ?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Arrêter le partage de position", role: .destructive) { Task { await trips.stop() } }
        } message: {
            Text("Le client ne verra plus votre position.")
        }
    }

    // MARK: En-tête
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trips.trip?.client ?? "").font(.title3.bold())
                Text(trips.trip?.address ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let s = trips.speedKmh, trips.isTracking {
                VStack(spacing: 0) {
                    Text("\(s)").font(.system(size: 26, weight: .heavy, design: .rounded))
                    Text("km/h").font(.caption2.bold()).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 54)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var networkPill: some View {
        HStack(spacing: 6) {
            Circle().fill(trips.online && trips.pending < 3 ? Brand.ok : .orange).frame(width: 8, height: 8)
            if !trips.online || trips.pending >= 3 {
                Text("Réseau faible · \(trips.pending) position(s) en attente")
            } else {
                Text("En direct avec le client")
            }
        }
        .font(.footnote.bold())
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Panneau bas
    private var panel: some View {
        VStack(spacing: 12) {
            if trips.isTracking {
                etaCards
                if let eta = trips.state?.eta, eta.jam {
                    Label("Ralentissement détecté : l'heure d'arrivée a été ajustée.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.bold()).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button { Task { await trips.arrived() } } label: {
                        Label("Je suis arrivé", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Brand.ok, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white).font(.headline)
                    }
                    Button { sendSms() } label: {
                        Label("SMS client", systemImage: "message.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                            .font(.headline)
                    }
                    .disabled((trips.trip?.phone ?? "").isEmpty)
                }
                HStack(spacing: 10) {
                    Button("Waze") { openNav(waze: true) }.buttonStyle(.bordered)
                    Button("Plans") { openNav(waze: false) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Arrêter", role: .destructive) { confirmStop = true }.buttonStyle(.bordered)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Brand.ok)
                    Text(trips.message ?? "Trajet terminé. Le partage de position est coupé.")
                        .multilineTextAlignment(.center).font(.headline)
                    Button { trips.close() } label: {
                        Text("Retour aux interventions").bold()
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Brand.blue, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                }
            }
            if let m = trips.message, trips.isTracking {
                Text(m).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.6))
    }

    private var etaCards: some View {
        let eta = trips.state?.eta
        let now = Int(Date().timeIntervalSince1970)
        return HStack(spacing: 8) {
            card("Arrivée", eta.map { Fmt.clock($0.at) } ?? "…")
            card("Restant", eta.map { Fmt.duration(max(60, $0.at - now)) } ?? "…")
            card("Distance", eta.map { Fmt.distance($0.distM) } ?? "…")
        }
    }

    private func card(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.paper, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sendSms() {
        guard let phone = trips.trip?.phone, !phone.isEmpty, let text = trips.enrouteMessage(),
              let body = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "sms:+\(phone)&body=\(body)") else { return }
        UIApplication.shared.open(url)
    }

    private func openNav(waze: Bool) {
        guard let c = trips.trip?.coordinate else { return }
        if waze, let u = URL(string: "https://waze.com/ul?ll=\(c.latitude),\(c.longitude)&navigate=yes") {
            UIApplication.shared.open(u)
        } else {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
            item.name = trips.trip?.client
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        }
    }
}

/// Carte Apple Plans (gratuite, intégrée à iOS) avec l'itinéraire calculé par le serveur.
struct TripMap: UIViewRepresentable {
    let route: [CLLocationCoordinate2D]
    let destination: CLLocationCoordinate2D?
    let follow: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        if follow { map.setUserTrackingMode(.followWithHeading, animated: false) }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.routeCount != route.count || c.routeFirst?.latitude != route.first?.latitude {
            map.removeOverlays(map.overlays)
            if route.count > 1 { map.addOverlay(MKPolyline(coordinates: route, count: route.count)) }
            c.routeCount = route.count
            c.routeFirst = route.first
        }
        if let d = destination, c.destAnnotation == nil {
            let a = MKPointAnnotation()
            a.coordinate = d
            a.title = "Client"
            map.addAnnotation(a)
            c.destAnnotation = a
        }
        if !c.didFit, let d = destination, let user = map.userLocation.location?.coordinate {
            let rect = [user, d].map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 1, height: 1)) }
                .reduce(MKMapRect.null) { $0.union($1) }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 50, bottom: 60, right: 50), animated: true)
            c.didFit = true
            if follow { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { map.setUserTrackingMode(.follow, animated: true) } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var routeCount = 0
        var routeFirst: CLLocationCoordinate2D?
        var destAnnotation: MKPointAnnotation?
        var didFit = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = UIColor(red: 0.078, green: 0.537, blue: 0.769, alpha: 1)
            r.lineWidth = 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "dest")
            v.markerTintColor = UIColor(red: 0.067, green: 0.078, blue: 0.071, alpha: 1)
            v.glyphImage = UIImage(systemName: "house.fill")
            return v
        }
    }
}
