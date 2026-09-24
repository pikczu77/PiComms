import SwiftUI

struct SignInView: View {
    @Environment(GoogleAuth.self) private var auth
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("PiComms")
                .font(.largeTitle.bold())
            Text("Prywatny czat dla dwojga.\nWiadomości są zapisywane na Twoim Google Drive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()

            if !Config.isConfigured {
                Text("Uzupełnij googleClientID w Config.swift (instrukcja w README).")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    if isSigningIn { ProgressView().tint(.white) }
                    Text("Zaloguj się przez Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSigningIn)
        }
        .padding(32)
    }

    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
        } catch AuthError.cancelled {
            // użytkownik zamknął okno logowania
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
