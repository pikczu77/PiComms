import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @Environment(GoogleAuth.self) private var auth
    @State private var draft = ""
    @State private var reauthError: String?
    @State private var showProfile = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if store.messages.isEmpty {
                            Text("Brak wiadomości. Napisz coś pierwszy! 💬")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                        ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(
                                store.messages[index - 1].date, inSameDayAs: message.date
                            ) {
                                DayHeader(date: message.date)
                            }
                            MessageRow(
                                message: message,
                                isMine: message.sender == store.myEmail,
                                senderProfile: store.profiles[message.sender],
                                showAvatar: isLastInGroup(at: index)
                            ) {
                                store.retry(message)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.messages.last?.id) { _, lastId in
                    guard let lastId else { return }
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .top) {
                if auth.needsReauth { reauthBanner }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showProfile = true
                    } label: {
                        AvatarView(profile: store.myProfile, size: 30)
                    }
                    .accessibilityLabel("Mój profil")
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileView(store: store)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AvatarView(profile: store.partnerProfile, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.partnerProfile?.displayName ?? "Czekam na drugą osobę…")
                    .font(.headline)
                    .lineLimit(1)
                if store.syncError != nil, !auth.needsReauth {
                    Text("Brak połączenia z Drive")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var reauthBanner: some View {
        Button {
            Task {
                do {
                    try await auth.signIn()
                    reauthError = nil
                    await store.refresh()
                } catch AuthError.cancelled {
                } catch {
                    reauthError = error.localizedDescription
                }
            }
        } label: {
            VStack(spacing: 2) {
                Label("Połączenie z Google wygasło – dotknij, aby połączyć", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                if let reauthError {
                    Text(reauthError).font(.caption2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .foregroundStyle(.white)
            .background(Color.orange)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Wiadomość", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button {
                store.send(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
            }
            .disabled(!canSend)
            .accessibilityLabel("Wyślij")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func isLastInGroup(at index: Int) -> Bool {
        let messages = store.messages
        guard index + 1 < messages.count else { return true }
        return messages[index + 1].sender != messages[index].sender
    }
}

private struct DayHeader: View {
    let date: Date

    var body: some View {
        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

private struct MessageRow: View {
    let message: Message
    let isMine: Bool
    let senderProfile: Profile?
    let showAvatar: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine {
                Spacer(minLength: 48)
            } else {
                AvatarView(profile: senderProfile, size: 28)
                    .opacity(showAvatar ? 1 : 0)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(isMine ? Color.white : Color.primary)
                    .background(
                        isMine ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .textSelection(.enabled)

                HStack(spacing: 4) {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                    switch message.status {
                    case .sent: EmptyView()
                    case .sending: Image(systemName: "clock")
                    case .failed:
                        Button(action: onRetry) {
                            Label("Nie wysłano – dotknij, aby ponowić", systemImage: "exclamationmark.circle.fill")
                        }
                        .foregroundStyle(.red)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !isMine { Spacer(minLength: 48) }
        }
    }
}
