import PhotosUI
import SwiftUI

struct ProfileView: View {
    let store: ChatStore
    @Environment(GoogleAuth.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var avatar: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        AvatarView(imageData: avatar, name: name, size: 110)
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text(avatar == nil ? "Dodaj zdjęcie" : "Zmień zdjęcie")
                        }
                        if avatar != nil {
                            Button("Usuń zdjęcie", role: .destructive) {
                                avatar = nil
                                pickerItem = nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderless)
                }

                Section("Nazwa użytkownika") {
                    TextField("Jak mam się wyświetlać?", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    LabeledContent("Konto Google", value: store.myEmail)
                    if let partner = store.partnerProfile {
                        LabeledContent("Rozmawiasz z", value: partner.displayName)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                Section {
                    Button("Wyloguj się", role: .destructive) { auth.signOut() }
                }
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Zapisz") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                name = store.myProfile?.displayName ?? ""
                avatar = store.myProfile?.avatar
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ImageProcessing.avatarJPEG(from: data) {
                        avatar = jpeg
                    } else {
                        errorMessage = "Nie udało się wczytać zdjęcia."
                    }
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await store.saveProfile(displayName: name, avatar: avatar)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
