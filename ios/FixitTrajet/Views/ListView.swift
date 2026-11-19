import SwiftUI
import UIKit
import CoreLocation

private struct DayGroup: Identifiable {
    let id: String
    let items: [Intervention]
}

struct ListView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var trips: TripManager
    @State private var items: [Intervention] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: Intervention?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange) }
                }
                if trips.authorization != .authorizedAlways {
                    Section {
                        Button {
                            if trips.authorization == .denied || trips.authorization == .restricted {
                                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                            } else {
                                trips.requestPermission()
                            }
                        } label: {
                            Label("Autoriser la position « Toujours » pour un suivi écran verrouillé", systemImage: "location.circle")
                        }
                    }
                }
                ForEach(groups) { group in
                    Section(group.id) {
                        ForEach(group.items) { iv in
                            Button { selected = iv } label: { Row(iv: iv) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if items.isEmpty && !loading && error == nil {
                    Section {
                        Text("Aucune intervention prévue. Créez-les depuis l'espace admin du site.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Interventions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $selected) { iv in
                DetailSheet(iv: iv) { selected = nil }
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Réglages", isPresented: $showSettings) {
                Button("Déconnecter cet iPhone", role: .destructive) { config.reset() }
            } message: {
                Text("Connecté à \(config.server)")
            }
        }
    }

    private var groups: [DayGroup] {
        let active = items.filter { ["enroute", "arrived", "working"].contains($0.status) }
        let planned = items.filter { $0.status == "planned" }
        var out: [DayGroup] = []
        if !active.isEmpty { out.append(DayGroup(id: "En cours", items: active)) }
        let byDay = Dictionary(grouping: planned) { Fmt.day($0.scheduledDate) }
        let keys = byDay.keys.sorted { (byDay[$0]?.first?.scheduledAt ?? 0) < (byDay[$1]?.first?.scheduledAt ?? 0) }
        for key in keys {
            out.append(DayGroup(id: key, items: byDay[key] ?? []))
        }
        return out
    }

    private func load() async {
        guard let api = config.client else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await api.list()
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
    }
}

private struct Row: View {
    let iv: Intervention
    var body: some View {
        HStack(spacing: 14) {
            Text(Fmt.clock(iv.scheduledAt))
                .font(.system(.title3, design: .rounded).bold())
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(iv.client).font(.headline)
                Text(iv.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if iv.status != "planned" {
                Text(iv.statusLabel).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Brand.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(Brand.blueDark)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private struct DetailSheet: View {
    let iv: Intervention
    let dismiss: () -> Void
    @EnvironmentObject var trips: TripManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Fmt.day(iv.scheduledDate)) · \(Fmt.clock(iv.scheduledAt))").font(.subheadline.bold()).foregroundStyle(Brand.blueDark)
                Text(iv.client).font(.title.bold())
                Text(iv.address).foregroundStyle(.secondary)
                if !iv.addressExtra.isEmpty { Text(iv.addressExtra).font(.footnote).foregroundStyle(.secondary) }
            }
            Button {
                Task {
                    await trips.start(iv)
                    if trips.trip != nil { dismiss() }
                }
            } label: {
                HStack {
                    Spacer()
                    if trips.busy { ProgressView().tint(.white) } else { Label("Je pars", systemImage: "car.fill").font(.title3.bold()) }
                    Spacer()
                }
                .padding(.vertical, 16)
                .background(Brand.blue, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .disabled(trips.busy)
            if let m = trips.message { Text(m).font(.footnote).foregroundStyle(.red) }
            HStack {
                if !iv.phone.isEmpty, let tel = URL(string: "tel:+\(iv.phone)") {
                    Link(destination: tel) { Label("Appeler", systemImage: "phone.fill") }
                        .buttonStyle(.bordered)
                }
                ShareLink(item: iv.link) { Label("Lien client", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            Text("Le client voit votre position uniquement pendant ce trajet. Elle n'est plus partagée dès votre arrivée.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(22)
    }
}
