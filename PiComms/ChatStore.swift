import Foundation
import Observation

/// Stan czatu. Dane żyją na Google Drive we wspólnym folderze „PiComms”:
///  - każda wiadomość to osobny plik JSON (properties: type=message, mid, sender),
///    dzięki czemu dwie osoby nigdy nie nadpisują sobie nawzajem danych,
///  - każda osoba ma jeden plik profilu (properties: type=profile, email)
///    z nazwą użytkownika i zdjęciem.
@MainActor
@Observable
final class ChatStore {
    enum Phase: Equatable {
        case loading
        case needsChat
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var myEmail = ""
    private(set) var messages: [Message] = []
    private(set) var profiles: [String: Profile] = [:]
    /// Ostatni błąd synchronizacji (np. brak internetu) – pokazywany dyskretnie w UI.
    private(set) var syncError: String?

    var myProfile: Profile? { profiles[myEmail] }
    var partnerProfile: Profile? {
        profiles.values
            .filter { $0.email != myEmail }
            .max { $0.updatedAt < $1.updatedAt }
    }

    @ObservationIgnored private let drive: DriveClient
    @ObservationIgnored private var googleDisplayName: String?
    @ObservationIgnored private var folderId: String?
    @ObservationIgnored private var lastSeenCreatedTime: String?
    @ObservationIgnored private var profileVersions: [String: String] = [:]
    @ObservationIgnored private var myProfileFileId: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false

    init(drive: DriveClient) {
        self.drive = drive
    }

    // MARK: - Start / zakładanie czatu

    func start() async {
        // Znana rozmowa: od razu pokazujemy czat z pamięci, a synchronizacja idzie w tle.
        // Dzięki temu brak internetu czy wygasłe logowanie Google nie wyrzucają z aplikacji.
        if let saved = SavedSession.load() {
            myEmail = saved.email
            if phase != .ready { await open(folderId: saved.folderId) }
            return
        }

        phase = .loading
        do {
            let user = try await drive.currentUser()
            myEmail = user.emailAddress.lowercased()
            googleDisplayName = user.displayName
            if let folder = try await findChatFolder() {
                await open(folderId: folder.id)
            } else {
                phase = .needsChat
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Tworzy wspólny folder na Twoim Drive i udostępnia go drugiej osobie.
    func createChat(inviting partnerEmail: String) async throws {
        let email = partnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folder = try await drive.createFolder(
            name: Config.chatFolderName,
            properties: ["picomms": "chat"]
        )
        try await drive.share(fileId: folder.id, with: email)
        await open(folderId: folder.id)
    }

    private func findChatFolder() async throws -> DriveFile? {
        // Znajduje zarówno folder utworzony przez nas, jak i udostępniony nam przez drugą osobę.
        let query = "mimeType='application/vnd.google-apps.folder' and "
            + "properties has { key='picomms' and value='chat' } and trashed=false"
        return try await drive.listFiles(query: query, orderBy: "createdTime").first
    }

    private func open(folderId: String) async {
        self.folderId = folderId
        SavedSession(email: myEmail, folderId: folderId).save()
        loadCache()
        phase = .ready
        let synced = await refresh()
        if synced, myProfileFileId == nil {
            let name = googleDisplayName ?? (try? await drive.currentUser().displayName) ?? myEmail
            try? await saveProfile(displayName: name, avatar: nil)
        }
        startPolling()
    }

    // MARK: - Synchronizacja

    func startPolling() {
        guard pollTask == nil, folderId != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Config.pollInterval)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing, let folderId else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await refreshMessages(folderId: folderId)
            try await refreshProfiles(folderId: folderId)
            syncError = nil
            return true
        } catch {
            syncError = error.localizedDescription
            return false
        }
    }

    private func refreshMessages(folderId: String) async throws {
        var query = "'\(folderId)' in parents and properties has { key='type' and value='message' } and trashed=false"
        if let lastSeenCreatedTime {
            query += " and createdTime >= '\(lastSeenCreatedTime)'"
        }
        let files = try await drive.listFiles(query: query, orderBy: "createdTime")
        let knownIds = Set(messages.filter { $0.status == .sent }.map(\.id))
        let newFiles = files.filter { file in
            guard let mid = file.properties?["mid"] else { return false }
            return !knownIds.contains(mid)
        }

        if !newFiles.isEmpty {
            let drive = self.drive
            let downloaded = try await withThrowingTaskGroup(of: Message?.self) { group in
                for file in newFiles {
                    group.addTask {
                        let data = try await drive.download(fileId: file.id)
                        guard let payload = try? JSONDecoder.drive.decode(MessagePayload.self, from: data) else {
                            return nil
                        }
                        return Message(
                            id: payload.id,
                            sender: payload.sender.lowercased(),
                            text: payload.text,
                            date: RFC3339.date(from: file.createdTime) ?? payload.sentAt
                        )
                    }
                }
                var result: [Message] = []
                for try await message in group {
                    if let message { result.append(message) }
                }
                return result
            }
            for message in downloaded {
                upsert(message)
            }
            sortMessages()
        }

        if let newest = files.last?.createdTime {
            lastSeenCreatedTime = newest
        }
        if !newFiles.isEmpty { saveCache() }
    }

    private func refreshProfiles(folderId: String) async throws {
        let query = "'\(folderId)' in parents and properties has { key='type' and value='profile' } and trashed=false"
        let files = try await drive.listFiles(query: query, orderBy: "modifiedTime desc")
        var seenEmails = Set<String>()
        var changed = false
        for file in files {
            guard let email = file.properties?["email"]?.lowercased(),
                  seenEmails.insert(email).inserted
            else { continue }
            if email == myEmail { myProfileFileId = file.id }
            if profileVersions[file.id] == file.modifiedTime, profiles[email] != nil { continue }

            let data = try await drive.download(fileId: file.id)
            if var profile = try? JSONDecoder.drive.decode(Profile.self, from: data) {
                profile.email = email
                profiles[email] = profile
                profileVersions[file.id] = file.modifiedTime
                changed = true
            }
        }
        if changed { saveCache() }
    }

    // MARK: - Wysyłanie

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = Message(id: UUID().uuidString, sender: myEmail, text: trimmed, date: Date(), status: .sending)
        messages.append(message)
        Task { await upload(message) }
    }

    func retry(_ message: Message) {
        guard message.status == .failed else { return }
        setStatus(.sending, for: message.id)
        Task { await upload(message) }
    }

    private func upload(_ message: Message) async {
        guard let folderId else { return }
        do {
            let payload = MessagePayload(id: message.id, sender: message.sender, text: message.text, sentAt: message.date)
            let file = try await drive.createFile(
                name: "msg-\(RFC3339.string(from: message.date))-\(message.id).json",
                parentId: folderId,
                properties: ["type": "message", "mid": message.id, "sender": message.sender],
                mimeType: "application/json",
                data: try JSONEncoder.drive.encode(payload)
            )
            var sent = message
            sent.status = .sent
            sent.date = RFC3339.date(from: file.createdTime) ?? message.date
            upsert(sent)
            sortMessages()
            saveCache()
        } catch {
            setStatus(.failed, for: message.id)
            saveCache()
        }
    }

    // MARK: - Profil

    func saveProfile(displayName: String, avatar: Data?) async throws {
        guard let folderId else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(
            email: myEmail,
            displayName: name.isEmpty ? myEmail : name,
            avatar: avatar,
            updatedAt: Date()
        )
        let data = try JSONEncoder.drive.encode(profile)

        let file: DriveFile
        if let myProfileFileId {
            file = try await drive.updateFileContent(fileId: myProfileFileId, mimeType: "application/json", data: data)
        } else {
            file = try await drive.createFile(
                name: "profile-\(myEmail).json",
                parentId: folderId,
                properties: ["type": "profile", "email": myEmail],
                mimeType: "application/json",
                data: data
            )
            myProfileFileId = file.id
        }
        profileVersions[file.id] = file.modifiedTime
        profiles[myEmail] = profile
        saveCache()
    }

    func displayName(for email: String) -> String {
        profiles[email]?.displayName ?? email
    }

    // MARK: - Pomocnicze

    private func upsert(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func sortMessages() {
        messages.sort { $0.date < $1.date }
    }

    private func setStatus(_ status: Message.Status, for id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = status
    }

    // MARK: - Zapamiętana rozmowa

    private struct SavedSession: Codable {
        static let key = "picomms.session"

        let email: String
        let folderId: String

        static func load() -> SavedSession? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(SavedSession.self, from: data)
        }

        func save() {
            if let data = try? JSONEncoder().encode(self) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    /// Wywoływane przy świadomym wylogowaniu – kolejne konto zacznie od wyszukania czatu.
    static func forgetSavedSession() {
        UserDefaults.standard.removeObject(forKey: SavedSession.key)
    }

    // MARK: - Lokalna pamięć podręczna (działa też offline)

    private struct Cache: Codable {
        var messages: [Message]
        var profiles: [String: Profile]
        var profileVersions: [String: String]
        var lastSeenCreatedTime: String?
    }

    private var cacheURL: URL? {
        guard let folderId,
              let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat-\(folderId).json")
    }

    private func loadCache() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder.drive.decode(Cache.self, from: data)
        else { return }
        messages = cache.messages.map { message in
            var message = message
            if message.status == .sending { message.status = .failed }
            return message
        }
        profiles = cache.profiles
        profileVersions = cache.profileVersions
        lastSeenCreatedTime = cache.lastSeenCreatedTime
    }

    private func saveCache() {
        guard let url = cacheURL else { return }
        let cache = Cache(
            messages: messages,
            profiles: profiles,
            profileVersions: profileVersions,
            lastSeenCreatedTime: lastSeenCreatedTime
        )
        if let data = try? JSONEncoder.drive.encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
