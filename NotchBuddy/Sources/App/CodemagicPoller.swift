import Foundation

// MARK: - CodemagicPoller
// Polls Codemagic every 30s: apps → recent builds → notch list + CI badge.
// Auth: Keychain `codemagic-api-token` → header `x-auth-token`.

final class CodemagicPoller: @unchecked Sendable {
    static let shared = CodemagicPoller()
    private var timer: DispatchSourceTimer?
    private var lastBuildKey: String = ""
    private var appNames: [String: String] = [:]

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 30)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.poll() }
    }

    // MARK: - Poll

    private func poll() {
        guard let token = KeychainStore.shared.get("codemagic-api-token"), !token.isEmpty else { return }
        fetchApps(token: token) { [weak self] apps in
            guard let self else { return }
            var names: [String: String] = [:]
            for a in apps { names[a.id] = a.name }
            self.appNames = names

            let filter: Set<String> = {
                if let d = UserDefaults.standard.data(forKey: "codemagicAppFilter"),
                   let a = try? JSONDecoder().decode([String].self, from: d) {
                    return Set(a)
                }
                return []
            }()
            let selectedIds: Set<String> = {
                if filter.isEmpty { return Set(apps.map(\.id)) }
                return Set(apps.filter { filter.contains($0.name) }.map(\.id))
            }()
            guard !selectedIds.isEmpty else {
                DispatchQueue.main.async {
                    Task { @MainActor in AppState.shared.codemagicBuilds = [] }
                }
                return
            }
            self.fetchBuilds(token: token, appIds: selectedIds)
        }
    }

    private func fetchApps(token: String, completion: @escaping ([(id: String, name: String)]) -> Void) {
        guard let url = URL(string: "https://api.codemagic.io/apps") else {
            completion([]); return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(token, forHTTPHeaderField: "x-auth-token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([]); return
            }
            let list = (root["applications"] as? [[String: Any]]) ?? []
            let apps: [(id: String, name: String)] = list.compactMap { row in
                let id = (row["_id"] as? String) ?? (row["id"] as? String)
                let name = (row["appName"] as? String) ?? (row["name"] as? String)
                guard let id, let name, !id.isEmpty, !name.isEmpty else { return nil }
                return (id, name)
            }
            completion(apps)
        }.resume()
    }

    private func fetchBuilds(token: String, appIds: Set<String>) {
        guard let url = URL(string: "https://api.codemagic.io/builds") else { return }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(token, forHTTPHeaderField: "x-auth-token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let list = (root["builds"] as? [[String: Any]])
                ?? (root["data"] as? [[String: Any]])
                ?? []

            var parsed: [CodemagicBuild] = []
            for row in list {
                guard let b = self.parseBuild(row) else { continue }
                if appIds.contains(b.appId) { parsed.append(b) }
            }
            // Prefer newest first; keep a short list for the notch card.
            parsed.sort { $0.createdAt > $1.createdAt }
            let top = Array(parsed.prefix(8))
            DispatchQueue.main.async {
                Task { @MainActor in self.handleBuilds(top) }
            }
        }.resume()
    }

    private func parseBuild(_ d: [String: Any]) -> CodemagicBuild? {
        let id = (d["_id"] as? String) ?? (d["id"] as? String)
        let appId = (d["appId"] as? String) ?? (d["applicationId"] as? String)
        let status = d["status"] as? String
        guard let id, let appId, let status, !id.isEmpty, !appId.isEmpty else { return nil }

        let appName = appNames[appId]
            ?? (d["appName"] as? String)
            ?? (d["applicationName"] as? String)
            ?? "App"

        let workflowId = d["workflowId"] as? String
        let workflowName = (d["workflowName"] as? String)
            ?? (d["workflow"] as? [String: Any])?["name"] as? String
            ?? workflowId

        let branch = d["branch"] as? String
        let tag = d["tag"] as? String

        let createdAt: Date = {
            if let s = d["createdAt"] as? String { return Self.parseISO(s) ?? Date() }
            if let s = d["startedAt"] as? String { return Self.parseISO(s) ?? Date() }
            if let n = d["createdAt"] as? Double { return Date(timeIntervalSince1970: n / 1000) }
            if let n = d["startedAt"] as? Double { return Date(timeIntervalSince1970: n / 1000) }
            if let n = d["createdAt"] as? Int { return Date(timeIntervalSince1970: Double(n) / 1000) }
            if let n = d["startedAt"] as? Int { return Date(timeIntervalSince1970: Double(n) / 1000) }
            return Date()
        }()

        let commitMessage: String? = {
            if let s = d["commit"] as? String, !s.isEmpty { return s }
            if let c = d["commit"] as? [String: Any] {
                return (c["message"] as? String) ?? (c["hash"] as? String)
            }
            return d["commitMessage"] as? String
        }()

        return CodemagicBuild(
            id: id,
            appId: appId,
            appName: appName,
            status: status,
            workflowId: workflowId,
            workflowName: workflowName,
            branch: branch,
            tag: tag,
            createdAt: createdAt,
            commitMessage: commitMessage
        )
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Codemagic sometimes returns millis as number encoded in JSON as Int — handled elsewhere.
        return nil
    }

    @MainActor
    private func handleBuilds(_ builds: [CodemagicBuild]) {
        let appState = AppState.shared
        appState.codemagicBuilds = builds

        if let inProgress = builds.first(where: { $0.isInProgress }) {
            guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_codemagic" }) else { return }
            appState.tasks[idx].state = .working
            appState.tasks[idx].steps = ["\(inProgress.appName) · \(inProgress.statusLabel)"]
            appState.tasks[idx].pillBadge = nil
            if AppState.shared.autoExpandCI {
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }
            return
        }

        guard let latest = builds.first(where: { $0.isTerminal }) else { return }
        let key = "\(latest.appId):\(latest.id):\(latest.status)"
        guard key != lastBuildKey else { return }
        lastBuildKey = key

        guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_codemagic" }) else { return }
        let focused = appState.focusId == "integration_codemagic"

        appState.tasks[idx].state = latest.isSuccess ? .finished : .error
        appState.tasks[idx].steps = ["\(latest.appName) · \(latest.statusLabel)"]

        if !focused {
            appState.tasks[idx].pillBadge = latest.isSuccess ? .finished : .error
        }
        SoundEngine.shared.play(latest.isSuccess ? "finish" : "error")
        NotificationCenter.default.post(
            name: .triggerEmote,
            object: latest.isSuccess ? BotEmote.happy : BotEmote.annoyed
        )
        if AppState.shared.autoExpandCI {
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = appState.tasks.firstIndex(where: { $0.id == "integration_codemagic" }) else { return }
            guard appState.tasks[i].state == .finished || appState.tasks[i].state == .error else { return }
            appState.tasks[i].state = .idle
            appState.tasks[i].steps = []
            appState.tasks[i].pillBadge = nil
        }
    }
}
