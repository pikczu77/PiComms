import SwiftUI

/// Pokazywany, gdy na Drive nie ma jeszcze wspólnego folderu czatu.
/// Jedna osoba tworzy czat i zaprasza drugą; druga osoba po prostu sprawdza zaproszenie.
struct SetupChatView: View {
    let store: ChatStore
    @Environment(GoogleAuth.self) private var auth
    @State private var partnerEmail = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Zalogowano jako \(store.myEmail)")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("adres@gmail.com", text: $partnerEmail)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await createChat() }
                    } label: {
                        HStack {
                            Text("Utwórz czat i wyślij zaproszenie")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isWorking || !partnerEmail.contains("@"))
                } header: {
                    Text("Zaproś drugą osobę")
                } footer: {
                    Text("Na Twoim Google Drive powstanie folder „\(Config.chatFolderName)”, udostępniony tej osobie.")
                }

                Section {
                    Button("Sprawdź, czy dostałem zaproszenie") {
                        Task { await store.start() }
                    }
                    .disabled(isWorking)
                } header: {
                    Text("Masz już zaproszenie?")
                } footer: {
                    Text("Jeśli druga osoba już utworzyła czat, aplikacja sama go znajdzie.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Wyloguj się", role: .destructive) { auth.signOut() }
                }
            }
            .navigationTitle("Nowy czat")
        }
    }

    private func createChat() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.createChat(inviting: partnerEmail)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
