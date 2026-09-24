import SwiftUI

@main
struct PiCommsApp: App {
    @State private var auth = GoogleAuth()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
        }
    }
}

struct RootView: View {
    @Environment(GoogleAuth.self) private var auth

    var body: some View {
        Group {
            if auth.isSignedIn {
                ChatContainerView(auth: auth)
            } else {
                SignInView()
            }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if !signedIn { ChatStore.forgetSavedSession() }
        }
    }
}

struct ChatContainerView: View {
    @State private var store: ChatStore
    @Environment(GoogleAuth.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    init(auth: GoogleAuth) {
        _store = State(initialValue: ChatStore(drive: DriveClient(auth: auth)))
    }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView("Łączenie z Google Drive…")
            case .needsChat:
                SetupChatView(store: store)
            case .ready:
                ChatView(store: store)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Coś poszło nie tak", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(message)
                } actions: {
                    Button("Spróbuj ponownie") { Task { await store.start() } }
                        .buttonStyle(.borderedProminent)
                    Button("Wyloguj się", role: .destructive) { auth.signOut() }
                }
            }
        }
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.startPolling()
                Task { await store.refresh() }
            } else {
                store.stopPolling()
            }
        }
        .onDisappear { store.stopPolling() }
    }
}
