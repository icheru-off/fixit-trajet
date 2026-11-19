import SwiftUI

struct RootView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var trips: TripManager

    var body: some View {
        Group {
            if !config.isConfigured {
                SetupView()
            } else if trips.trip != nil {
                TripView()
            } else {
                ListView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: trips.trip?.id)
    }
}

struct SetupView: View {
    @EnvironmentObject var config: AppConfig
    @State private var server = ""
    @State private var key = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FixIT Trajet").font(.largeTitle.bold())
                        Text("Partage votre position avec le client pendant le trajet, même écran verrouillé et en zone sans réseau.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Label("Le plus simple : ouvrez Réglages sur votre site de suivi depuis cet iPhone et touchez « Configurer l'app automatiquement ».", systemImage: "link")
                        .font(.callout)
                }
                Section("Ou saisie manuelle") {
                    TextField("Adresse du serveur (ex. suivi.fixit-service.fr)", text: $server)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Clé de l'application", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { try await config.save(server: server, key: key); error = nil }
                            catch let e { error = e.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy {
                                ProgressView()
                            } else {
                                Text("Tester et enregistrer").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(server.isEmpty || key.isEmpty || busy)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
        }
    }
}
