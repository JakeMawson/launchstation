import AppKit
import Combine
import Foundation
import LauncherCore
import UniformTypeIdentifiers

enum LauncherListSortOrder: String {
    case alphabetical
    case recentlyRun

    mutating func toggle() {
        self = self == .alphabetical ? .recentlyRun : .alphabetical
    }
}

@MainActor
final class LauncherViewModel: ObservableObject {
    struct AlertMessage: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    struct CloseConfirmation: Identifiable, Equatable {
        struct Target: Equatable {
            var sessionID: UUID
            var activeActionRunIDs: Set<UUID>
            var serviceNames: [String]
        }

        let id = UUID()
        var launcherID: UUID
        var launcherName: String
        var targets: [Target]

        var closesAll: Bool { targets.count > 1 }

        var buttonTitle: String {
            closesAll ? "Close all \(launcherName) sessions" : "Close \(launcherName)"
        }

        var message: String {
            if closesAll {
                let count = targets.count
                return "Close all \(count) exact active sessions for \(launcherName)? If any session or its active services change before confirmation, Launcher will ask you to confirm again."
            }
            let services = targets[0].serviceNames.isEmpty
                ? "its active processes"
                : targets[0].serviceNames.joined(separator: ", ")
            return "Close the exact active session for \(launcherName)? This will stop \(services). If that session changes before confirmation, Launcher will ask you to confirm again."
        }
    }

    struct RelaunchConfirmation: Identifiable, Equatable {
        let id = UUID()
        var intent: LauncherRelaunchIntent

        var launcherName: String { intent.launcherName }

        var message: String {
            let services = intent.activeServiceNames.isEmpty
                ? "its active processes"
                : intent.activeServiceNames.joined(separator: ", ")
            let arguments = intent.runtimeArguments.isEmpty
                ? "no extra runtime arguments"
                : intent.runtimeArguments.map(ShellEscaping.quote).joined(separator: " ")
            return "Fully close the exact active session for \(launcherName), including \(services), then start a fresh session with new managed ports where configured and \(arguments)? If that session changes before confirmation, Launcher will ask you to confirm again."
        }
    }

    struct LogPresentation: Identifiable, Equatable {
        let id: UUID
        var sessionID: UUID
        var launcherName: String
        var text: String
        var diagnoses: [LaunchFailureDiagnosis]
        var isLoading: Bool
        var errorMessage: String?

        init(sessionID: UUID, launcherName: String) {
            id = UUID()
            self.sessionID = sessionID
            self.launcherName = launcherName
            text = ""
            diagnoses = []
            isLoading = true
            errorMessage = nil
        }
    }

    struct HistoryPresentation: Identifiable, Equatable {
        let id: UUID
        var launcherID: UUID?
        var sessions: [SessionRecord]
        var selectedSessionID: UUID?
        var nextCursor: String?
        var isLoading: Bool
        var isLoadingMore: Bool
        var errorMessage: String?

        init(launcherID: UUID? = nil, selectedSession: SessionRecord? = nil) {
            id = UUID()
            self.launcherID = launcherID
            sessions = selectedSession.map { [$0] } ?? []
            selectedSessionID = selectedSession?.id
            nextCursor = nil
            isLoading = true
            isLoadingMore = false
            errorMessage = nil
        }

        var selectedSession: SessionRecord? {
            guard let selectedSessionID else { return sessions.first }
            return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
        }
    }

    struct ExternalClosePresentation: Identifiable, Equatable {
        let id = UUID()
        var intent: ExternalCloseIntent
        var confirmationText = ""
    }

    struct ExternalDraftPresentation: Identifiable, Equatable {
        enum Origin: Equatable {
            case externalObservation
            case manual
        }

        let id = UUID()
        var draft: ExternalLauncherDraft
        var origin: Origin
        var fixedPortText: String
        var argumentsText: String
        var argumentsError: String?
        var openInBrowser: Bool

        init(draft: ExternalLauncherDraft, origin: Origin = .externalObservation) {
            var editableDraft = draft
            // Opening the editor is not itself command approval. Even an exactly parsed command
            // must receive one explicit human acknowledgement before it can become runnable.
            editableDraft.commandReviewComplete = false
            self.draft = editableDraft
            self.origin = origin
            fixedPortText = draft.portPolicy.fixedPort.map(String.init) ?? ""
            argumentsText = draft.arguments.map(ShellEscaping.quote).joined(separator: " ")
            argumentsError = nil
            let command = draft.displayCommand.lowercased()
            openInBrowser = [
                "http.server", "vite", "next", "nuxt", "webpack", "npm", "pnpm", "yarn",
                "uvicorn", "gunicorn", "flask", "django", "rails", "localhost",
            ].contains { command.contains($0) }
        }

        var canSave: Bool {
            draft.canSave && (draft.runner != .process || argumentsError == nil)
        }
    }

    /// A local, revision-bound copy of an existing launcher. The sheet never writes project
    /// files directly: Save uses the daemon's normal launcher/action update routes, so the
    /// generated read-only `launch_details.md` remains daemon-owned.
    struct LauncherEditPresentation: Identifiable, Equatable {
        let id = UUID()
        var original: LauncherDetail
        var draft: LauncherRecord
        var tagsText: String
        var argumentsText: [UUID: String]
        var argumentsErrors: [UUID: String]
        var isSaving = false

        init(detail: LauncherDetail) {
            original = detail
            draft = detail.launcher
            tagsText = detail.launcher.tags.joined(separator: ", ")
            argumentsText = Dictionary(
                uniqueKeysWithValues: detail.launcher.actions.map { action in
                    (action.id, action.arguments.map(ShellEscaping.quote).joined(separator: " "))
                }
            )
            argumentsErrors = [:]
        }

        var canSave: Bool {
            !isSaving && argumentsErrors.isEmpty
        }
    }

    struct SkillUninstallPresentation: Identifiable, Equatable {
        let id = UUID()
        var presenterID: UUID
        var intent: LauncherSkillUninstallIntent
        var confirmationText = ""
    }

    /// A short-lived, server-authorized request to remove one saved launcher shortcut.
    /// The daemon-issued capability stays in app memory only, and the editor's unsaved
    /// changes are never sent as part of a deletion request.
    struct LauncherDeletePresentation: Identifiable, Equatable {
        let id = UUID()
        var presenterID: UUID
        var intent: DeleteIntent
        var confirmationText = ""
    }

    @Published private(set) var snapshot: CatalogSnapshot?
    @Published var selectedLauncherID: UUID?
    @Published var searchText = ""
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStartingService = false
    @Published private(set) var connectionError: String?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var startingLauncherIDs: Set<UUID> = []
    @Published private(set) var startingAdditionalLauncherIDs: Set<UUID> = []
    @Published private(set) var stoppingSessionIDs: Set<UUID> = []
    @Published private(set) var relaunchingSessionIDs: Set<UUID> = []
    @Published private var transientSessions: [UUID: SessionRecord] = [:]
    @Published private var transientSessionDates: [UUID: Date] = [:]
    @Published private(set) var recentSessions: [SessionRecord] = []
    @Published private(set) var isLoadingRecentHistory = false
    @Published var historyPresentation: HistoryPresentation?
    @Published var runtimeArgumentText: [UUID: String] = [:]
    @Published var alertMessage: AlertMessage?
    @Published private var scopedAlertMessages: [UUID: AlertMessage] = [:]
    @Published var closeConfirmation: CloseConfirmation?
    @Published var relaunchConfirmation: RelaunchConfirmation?
    @Published var logPresentation: LogPresentation?
    @Published private(set) var launcherSkillStatus: LauncherSkillStatus?
    @Published private(set) var launcherSkillStatusError: String?
    @Published private(set) var installingSkillHosts: Set<LauncherSkillHost> = []
    @Published private(set) var isRefreshingSkillStatus = false
    @Published private(set) var isDownloadingSkill = false
    @Published var isSkillInstallerPresented = false
    @Published private(set) var focusSearchRequest = 0
    @Published private(set) var externalProcessSnapshot: ExternalProcessSnapshot?
    @Published private(set) var isRefreshingExternalProcesses = false
    @Published private(set) var externalProcessError: String?
    @Published var selectedExternalObservationID: UUID?
    @Published var externalClosePresentation: ExternalClosePresentation?
    @Published var externalDraftPresentation: ExternalDraftPresentation?
    @Published var launcherEditPresentation: LauncherEditPresentation?
    @Published private(set) var isPreparingExternalClose = false
    @Published private(set) var isLoadingExternalDraft = false
    @Published private(set) var isSavingExternalDraft = false
    @Published private(set) var sessionOpenOptions: [UUID: [SessionOpenOption]] = [:]
    @Published private(set) var loadingSessionOpenOptionIDs: Set<UUID> = []
    @Published private(set) var sessionOpenOptionErrors: [UUID: String] = [:]
    @Published private(set) var openingSessionOptionIDs: Set<String> = []
    @Published private(set) var probingSessionOptionIDs: Set<String> = []
    @Published var skillUninstallPresentation: SkillUninstallPresentation?
    @Published private(set) var isPreparingSkillUninstall = false
    @Published private(set) var isUninstallingSkill = false
    @Published var launcherDeletePresentation: LauncherDeletePresentation?
    @Published private(set) var isPreparingLauncherDeletion = false
    @Published private(set) var isDeletingLauncher = false

    private let client: LauncherAPIClient
    private var pollingTask: Task<Void, Never>?
    private var skillStatusRequestGeneration = 0
    private var skillUninstallRequestGeneration = 0
    private var skillUninstallPreparingPresenterID: UUID?
    private var launcherDeleteRequestGeneration = 0
    private var launcherDeletePreparingPresenterID: UUID?
    private var externalProcessRequestGeneration = 0
    private var lastExternalProcessRequestAt: Date?
    private var activeScopedAlertPresenterIDs: Set<UUID> = []

    init(client: LauncherAPIClient) {
        self.client = client
    }

    func scopedAlertMessage(for presenterID: UUID) -> AlertMessage? {
        guard activeScopedAlertPresenterIDs.contains(presenterID) else { return nil }
        return scopedAlertMessages[presenterID]
    }

    func setScopedAlertMessage(_ message: AlertMessage?, for presenterID: UUID) {
        if let message {
            guard activeScopedAlertPresenterIDs.contains(presenterID) else { return }
            scopedAlertMessages[presenterID] = message
        } else {
            scopedAlertMessages.removeValue(forKey: presenterID)
        }
    }

    func registerScopedAlertPresenter(_ presenterID: UUID) {
        activeScopedAlertPresenterIDs.insert(presenterID)
    }

    func unregisterScopedAlertPresenter(_ presenterID: UUID) {
        activeScopedAlertPresenterIDs.remove(presenterID)
        scopedAlertMessages.removeValue(forKey: presenterID)
        if skillUninstallPresentation?.presenterID == presenterID {
            skillUninstallPresentation = nil
        }
        if skillUninstallPreparingPresenterID == presenterID {
            skillUninstallRequestGeneration += 1
            skillUninstallPreparingPresenterID = nil
            isPreparingSkillUninstall = false
        }
        if launcherDeletePresentation?.presenterID == presenterID {
            launcherDeletePresentation = nil
        }
        if launcherDeletePreparingPresenterID == presenterID {
            launcherDeleteRequestGeneration += 1
            launcherDeletePreparingPresenterID = nil
            isPreparingLauncherDeletion = false
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    var launchers: [LauncherDetail] {
        (snapshot?.launchers ?? []).sorted(by: launcherSort)
    }

    var filteredLaunchers: [LauncherDetail] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return launchers }
        let normalized = LauncherValidation.normalizeName(query)
        return launchers.filter { detail in
            let searchable = [
                detail.launcher.name,
                detail.project.displayName,
                detail.project.directory,
                detail.launcher.tags.joined(separator: " ")
            ].joined(separator: " ")
            return LauncherValidation.normalizeName(searchable).contains(normalized)
        }
    }

    var runningLaunchers: [LauncherDetail] {
        filteredLaunchers.filter { activeSession(for: $0) != nil }
    }

    var nonRunningLaunchers: [LauncherDetail] {
        filteredLaunchers.filter { activeSession(for: $0) == nil }
    }

    func runningLaunchers(sortedBy order: LauncherListSortOrder) -> [LauncherDetail] {
        displayedLaunchers(sortedBy: order).filter { activeSession(for: $0) != nil }
    }

    func nonRunningLaunchers(sortedBy order: LauncherListSortOrder) -> [LauncherDetail] {
        displayedLaunchers(sortedBy: order).filter { activeSession(for: $0) == nil }
    }

    var observedExternalProcesses: [ExternalProcessObservation] {
        let query = LauncherValidation.normalizeName(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (externalProcessSnapshot?.observations ?? [])
            .filter { observation in
                guard observation.ownership.kind != .launcherOwned else { return false }
                guard !query.isEmpty else { return true }
                let searchable = [
                    observation.command.displayCommand,
                    observation.workingDirectory ?? "",
                    observation.endpoints.map(\.displayValue).joined(separator: " "),
                    "PID \(observation.pid)",
                ].joined(separator: " ")
                return LauncherValidation.normalizeName(searchable).contains(query)
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.pid < rhs.pid
            }
    }

    var selectedExternalObservation: ExternalProcessObservation? {
        guard let selectedExternalObservationID else { return nil }
        return externalProcessSnapshot?.observations.first(where: {
            $0.id == selectedExternalObservationID && $0.ownership.kind != .launcherOwned
        })
    }

    var selectedDetail: LauncherDetail? {
        guard let selectedLauncherID else { return nil }
        return launchers.first(where: { $0.id == selectedLauncherID })
    }

    var selectedActiveSession: SessionRecord? {
        selectedDetail.flatMap(activeSession(for:))
    }

    var hasAnyActiveSession: Bool {
        launchers.contains { activeSession(for: $0) != nil }
    }

    var isConnected: Bool {
        snapshot != nil && connectionError == nil
    }

    var canLaunchSelected: Bool {
        guard let detail = selectedDetail else { return false }
        return activeSessions(for: detail).isEmpty && !startingLauncherIDs.contains(detail.id) && connectionError == nil
    }

    var canStopSelected: Bool {
        guard let detail = selectedDetail,
              let session = activeSession(for: detail) else { return false }
        return !activeSessions(for: detail).contains {
            stoppingSessionIDs.contains($0.id) || $0.state == .stopping
        } && session.isActive && connectionError == nil
    }

    var canRelaunchSelected: Bool {
        guard let detail = selectedDetail,
              let session = primaryActiveSession(for: detail) else { return false }
        return canRelaunch(session)
    }

    var shouldShowSkillPrompt: Bool {
        guard launcherSkillStatusError == nil, let status = launcherSkillStatus else { return false }
        let available = status.hosts.filter(\.available)
        if available.isEmpty { return true }
        return available.contains(where: { $0.state != .current })
    }

    func skillStatus(for host: LauncherSkillHost) -> LauncherSkillHostStatus? {
        launcherSkillStatus?.hosts.first(where: { $0.host == host })
    }

    var isInstallingAnySkill: Bool {
        !installingSkillHosts.isEmpty
    }

    var hasPendingSkillUninstall: Bool {
        skillUninstallPresentation != nil
    }

    func isInstallingSkill(for host: LauncherSkillHost) -> Bool {
        installingSkillHosts.contains(host)
    }

    func activeSessions(for detail: LauncherDetail) -> [SessionRecord] {
        var sessionsByID = [UUID: SessionRecord]()
        for session in detail.activeSessions where session.launcherID == detail.launcher.id && session.isActive {
            sessionsByID[session.id] = session
        }
        if let legacySession = detail.activeSession,
           legacySession.launcherID == detail.launcher.id,
           legacySession.isActive {
            sessionsByID[legacySession.id] = legacySession
        }
        for session in transientSessions.values where session.launcherID == detail.launcher.id && session.isActive {
            sessionsByID[session.id] = session
        }
        return sessionsByID.values.sorted(by: sessionSort)
    }

    func activeSession(for detail: LauncherDetail) -> SessionRecord? {
        activeSessions(for: detail).first(where: { $0.launchRole == .primary })
            ?? activeSessions(for: detail).first
    }

    func primaryActiveSession(for detail: LauncherDetail) -> SessionRecord? {
        activeSessions(for: detail).first(where: { $0.launchRole == .primary })
    }

    func activeSession(id: UUID, for detail: LauncherDetail) -> SessionRecord? {
        activeSessions(for: detail).first(where: { $0.id == id })
    }

    func isRelaunching(_ session: SessionRecord) -> Bool {
        relaunchingSessionIDs.contains(session.id)
    }

    func canRelaunch(_ session: SessionRecord) -> Bool {
        !isRelaunching(session)
            && !stoppingSessionIDs.contains(session.id)
            && session.state != .stopping
            && connectionError == nil
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            // Establish the daemon connection before dependent panels request their data. When
            // launchd must restore the service, this keeps the outage in one explicit startup
            // state instead of producing catalog, listener, and skill errors simultaneously.
            await self.connectOnLaunch()
            if self.isConnected {
                await self.refreshExternalProcesses(silent: true)
            }
            while !Task.isCancelled {
                let interval: UInt64 = self.hasAnyActiveSession ? 1_000_000_000 : 3_000_000_000
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
                await self.refresh(silent: true)
                await self.refreshExternalProcesses(silent: true)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func connectOnLaunch() async {
        isInitialLoading = true
        isRefreshing = true
        defer {
            isStartingService = false
            isInitialLoading = false
            isRefreshing = false
        }

        do {
            do {
                _ = try await client.probeHealth()
            } catch let error as LauncherAPIError {
                if case .invalidMetadata = error { throw error }
                isStartingService = true
                connectionError = nil
                alertMessage = nil
                _ = try await client.startServiceAndWaitUntilReady()
            }

            let catalog = try await client.snapshot()
            acceptCatalog(catalog, refreshSkillStatus: true)
        } catch is CancellationError {
            return
        } catch {
            connectionError = error.localizedDescription
            alertMessage = AlertMessage(
                title: "Launcher service unavailable",
                message: error.localizedDescription
            )
        }
    }

    func refresh(silent: Bool = false) async {
        if !silent { isRefreshing = true }
        defer {
            isInitialLoading = false
            if !silent { isRefreshing = false }
        }

        do {
            let catalog = try await client.snapshot()
            acceptCatalog(catalog, refreshSkillStatus: !silent || launcherSkillStatus == nil)
        } catch is CancellationError {
            return
        } catch {
            connectionError = error.localizedDescription
            if snapshot == nil && !silent {
                alertMessage = AlertMessage(
                    title: "Launcher service unavailable",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func acceptCatalog(_ catalog: CatalogSnapshot, refreshSkillStatus: Bool) {
        snapshot = catalog
        connectionError = nil
        lastUpdatedAt = Date()
        reconcileTransientSessions(with: catalog)
        reconcileSelection(with: catalog)
        if refreshSkillStatus {
            // Host authentication can require code-signature validation and a bounded CLI
            // version probe. It is useful UI metadata, but it must not keep the catalog
            // refresh indicator spinning or delay the actual launcher controls.
            Task { [weak self] in
                await self?.refreshLauncherSkillStatus(silent: true)
            }
        }
    }

    /// External inspection is intentionally independent from the catalog refresh. The daemon
    /// owns the expensive listener inventory and can return a cached snapshot; the GUI only
    /// asks frequently enough to keep a selected observation useful without thrashing lsof.
    func refreshExternalProcesses(fresh: Bool = false, silent: Bool = false) async {
        let now = Date()
        if !fresh,
           let lastExternalProcessRequestAt,
           now.timeIntervalSince(lastExternalProcessRequestAt) < 8 {
            return
        }
        externalProcessRequestGeneration &+= 1
        let generation = externalProcessRequestGeneration
        lastExternalProcessRequestAt = now
        // On a fresh app launch there is no prior inventory to display. Surface a compact,
        // truthful loading state instead of briefly rendering “No separately started
        // listeners” while the first bounded lsof scan is still in flight.
        let shouldPresentLoading = !silent || externalProcessSnapshot == nil
        if shouldPresentLoading { isRefreshingExternalProcesses = true }
        defer {
            if shouldPresentLoading { isRefreshingExternalProcesses = false }
        }
        do {
            let snapshot = try await client.externalProcessSnapshot(fresh: fresh)
            guard generation == externalProcessRequestGeneration else { return }
            externalProcessSnapshot = snapshot
            externalProcessError = nil
            if let selectedExternalObservationID,
               !snapshot.observations.contains(where: { $0.id == selectedExternalObservationID && $0.ownership.kind != .launcherOwned }) {
                self.selectedExternalObservationID = nil
                // The observed process is gone, so return to the normal managed-selection
                // fallback immediately instead of leaving the inspector blank until the next
                // catalog poll. While an external observation remains selected, the catalog
                // reconciliation deliberately does nothing (see `reconcileSelection`).
                if let catalog = self.snapshot {
                    reconcileSelection(with: catalog)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == externalProcessRequestGeneration else { return }
            externalProcessError = error.localizedDescription
            if !silent {
                alertMessage = AlertMessage(title: "External listeners unavailable", message: error.localizedDescription)
            }
        }
    }

    func selectManagedLauncher(_ launcherID: UUID) {
        selectedExternalObservationID = nil
        selectedLauncherID = launcherID
    }

    func selectExternalProcess(_ observation: ExternalProcessObservation) {
        // An external listener is an inspector choice, not a synthetic managed session. It must
        // nevertheless be mutually exclusive with a managed List selection: retaining the old
        // launcher ID leaves two rows highlighted and lets a catalog refresh reveal the old
        // inspector as an apparent selection jump.
        selectedExternalObservationID = observation.id
        selectedLauncherID = nil
    }

    func openExternalEndpoint(_ endpoint: ExternalListenerEndpoint) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = endpoint.loopbackHost
        components.port = endpoint.port
        components.path = "/"
        guard let url = components.url else {
            alertMessage = AlertMessage(
                title: "Port cannot be opened",
                message: "Could not form a browser URL for \(endpoint.displayValue)."
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestExternalClose(for observation: ExternalProcessObservation) async {
        guard observation.canClose, !isPreparingExternalClose else { return }
        isPreparingExternalClose = true
        defer { isPreparingExternalClose = false }
        await refreshExternalProcesses(fresh: true, silent: true)
        do {
            let intent = try await client.makeExternalCloseIntent(observationID: observation.id)
            externalClosePresentation = ExternalClosePresentation(intent: intent)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t prepare external close", message: error.localizedDescription)
        }
    }

    func confirmExternalClose(_ presentation: ExternalClosePresentation) async {
        guard presentation.confirmationText == presentation.intent.confirmationText else { return }
        externalClosePresentation = nil
        do {
            let result = try await client.closeExternalProcess(
                ExternalCloseRequest(
                    observationID: presentation.intent.observationID,
                    intentToken: presentation.intent.token,
                    confirmationText: presentation.confirmationText
                )
            )
            alertMessage = AlertMessage(title: "External listener close", message: result.message)
            await refreshExternalProcesses(fresh: true, silent: true)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t close external listener", message: error.localizedDescription)
            await refreshExternalProcesses(fresh: true, silent: true)
        }
    }

    func requestExternalLauncherDraft(for observation: ExternalProcessObservation) async {
        guard !isLoadingExternalDraft else { return }
        isLoadingExternalDraft = true
        defer { isLoadingExternalDraft = false }
        await refreshExternalProcesses(fresh: true, silent: true)
        do {
            let draft = try await client.externalLauncherDraft(observationID: observation.id)
            externalDraftPresentation = ExternalDraftPresentation(draft: draft, origin: .externalObservation)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t prepare launcher draft", message: error.localizedDescription)
        }
    }

    func presentManualLauncherDraft() {
        guard !isSavingExternalDraft else { return }
        externalDraftPresentation = ExternalDraftPresentation(
            draft: ExternalLauncherDraft(
                sourceObservationID: UUID(),
                name: "",
                description: "",
                projectDirectory: "",
                runner: .process,
                executable: nil,
                arguments: [],
                shellCommand: nil,
                displayCommand: "",
                observedEndpoints: [],
                portPolicy: ExternalDraftPortPolicy(mode: .reviewRequired),
                commandReviewComplete: false,
                sourceHadRedactions: false,
                sourceWasSanitized: false
            ),
            origin: .manual
        )
    }

    func presentLauncherEditor(for detail: LauncherDetail) {
        guard !isSavingExternalDraft else { return }
        launcherEditPresentation = LauncherEditPresentation(detail: detail)
    }

    func updateLauncherEditor(_ update: (inout LauncherEditPresentation) -> Void) {
        guard var presentation = launcherEditPresentation, !presentation.isSaving else { return }
        update(&presentation)
        launcherEditPresentation = presentation
    }

    func updateLauncherEditorAction(_ actionID: UUID, _ update: (inout LaunchAction) -> Void) {
        updateLauncherEditor { presentation in
            guard let index = presentation.draft.actions.firstIndex(where: { $0.id == actionID }) else { return }
            update(&presentation.draft.actions[index])
        }
    }

    func setLauncherEditorArguments(_ value: String, for actionID: UUID) {
        updateLauncherEditor { presentation in
            presentation.argumentsText[actionID] = value
            do {
                let arguments = try RuntimeArgumentParser.parse(value)
                guard let index = presentation.draft.actions.firstIndex(where: { $0.id == actionID }) else { return }
                presentation.draft.actions[index].arguments = arguments
                presentation.argumentsErrors.removeValue(forKey: actionID)
            } catch {
                presentation.argumentsErrors[actionID] = error.localizedDescription
            }
        }
    }

    func saveLauncherEditor() async {
        guard var presentation = launcherEditPresentation,
              presentation.canSave else { return }
        presentation.isSaving = true
        launcherEditPresentation = presentation
        defer {
            if var visible = launcherEditPresentation, visible.id == presentation.id {
                visible.isSaving = false
                launcherEditPresentation = visible
            }
        }

        do {
            var latest = presentation.original
            let draft = presentation.draft
            let trimmedRunDetails = draft.runDetails?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let metadataChanged = draft.name != latest.launcher.name
                || draft.description != latest.launcher.description
                || trimmedRunDetails != (latest.launcher.runDetails ?? "")
                || presentation.tagsText != latest.launcher.tags.joined(separator: ", ")
            if metadataChanged {
                let parsedTags = presentation.tagsText
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                latest = try await client.updateLauncher(
                    id: latest.id,
                    patch: LauncherPatchRequest(
                        expectedRevision: latest.launcher.revision,
                        name: draft.name,
                        description: draft.description,
                        runDetails: trimmedRunDetails.isEmpty ? nil : trimmedRunDetails,
                        clearRunDetails: trimmedRunDetails.isEmpty,
                        replaceTags: parsedTags
                    )
                )
            }

            for draftAction in draft.sortedActions {
                guard let currentAction = latest.launcher.actions.first(where: { $0.id == draftAction.id }) else {
                    throw LauncherAPIError.invalidResponse
                }
                guard draftAction != currentAction else { continue }
                latest = try await client.updateAction(
                    launcherID: latest.id,
                    actionID: draftAction.id,
                    requestBody: ActionPatchRequest(
                        expectedRevision: latest.launcher.revision,
                        action: draftAction
                    )
                )
            }

            launcherEditPresentation = nil
            selectedExternalObservationID = nil
            selectedLauncherID = latest.id
            await refresh(silent: true)
        } catch {
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t update launcher", message: error.localizedDescription),
                for: presentation.id
            )
        }
    }

    func requestLauncherDeletion(
        for detail: LauncherDetail,
        presenterID: UUID
    ) async {
        guard launcherEditPresentation?.id == presenterID,
              launcherDeletePresentation == nil,
              !isPreparingLauncherDeletion,
              !isDeletingLauncher else { return }
        launcherDeleteRequestGeneration += 1
        let generation = launcherDeleteRequestGeneration
        launcherDeletePreparingPresenterID = presenterID
        isPreparingLauncherDeletion = true
        defer {
            if launcherDeleteRequestGeneration == generation {
                launcherDeletePreparingPresenterID = nil
                isPreparingLauncherDeletion = false
            }
        }

        do {
            let intent = try await client.deleteIntent(launcherID: detail.id)
            guard launcherDeleteRequestGeneration == generation,
                  activeScopedAlertPresenterIDs.contains(presenterID),
                  launcherEditPresentation?.id == presenterID,
                  launcherDeletePresentation == nil else { return }
            launcherDeletePresentation = LauncherDeletePresentation(
                presenterID: presenterID,
                intent: intent
            )
        } catch {
            guard launcherDeleteRequestGeneration == generation else { return }
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t prepare launcher deletion", message: error.localizedDescription),
                for: presenterID
            )
            await refresh(silent: true)
        }
    }

    func confirmLauncherDeletion(_ presentation: LauncherDeletePresentation) async {
        guard let current = launcherDeletePresentation,
              current.id == presentation.id,
              current.presenterID == presentation.presenterID,
              current.intent == presentation.intent,
              current.confirmationText == presentation.confirmationText,
              presentation.confirmationText == presentation.intent.launcher.launcher.name,
              launcherEditPresentation?.id == presentation.presenterID,
              !isDeletingLauncher else { return }
        isDeletingLauncher = true
        defer { isDeletingLauncher = false }

        // The daemon capability is single-use. Dismiss this confirmation before sending the
        // destructive request so a failed attempt always requires fresh server inspection.
        launcherDeletePresentation = nil
        do {
            _ = try await client.deleteLauncher(
                id: presentation.intent.launcher.id,
                requestBody: DeleteRequest(
                    expectedRevision: presentation.intent.launcher.launcher.revision,
                    intentToken: presentation.intent.token
                )
            )
            let deletedName = presentation.intent.launcher.launcher.name
            launcherEditPresentation = nil
            if selectedLauncherID == presentation.intent.launcher.id {
                selectedLauncherID = nil
            }
            await refresh(silent: true)
            alertMessage = AlertMessage(
                title: "Launcher deleted",
                message: "Deleted the \(deletedName) shortcut. Project files, external processes, and launcher history were not deleted."
            )
        } catch {
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t delete launcher", message: error.localizedDescription),
                for: presentation.presenterID
            )
            await refresh(silent: true)
        }
    }

    func cancelLauncherDeletion(_ presentation: LauncherDeletePresentation) {
        guard let current = launcherDeletePresentation,
              current.id == presentation.id,
              current.presenterID == presentation.presenterID,
              current.intent == presentation.intent else { return }
        launcherDeletePresentation = nil
    }

    func updateExternalDraft(_ update: (inout ExternalLauncherDraft) -> Void) {
        guard var presentation = externalDraftPresentation else { return }
        update(&presentation.draft)
        presentation.fixedPortText = presentation.draft.portPolicy.fixedPort.map(String.init) ?? ""
        externalDraftPresentation = presentation
    }

    func setExternalDraftFixedPort(_ value: String) {
        guard var presentation = externalDraftPresentation else { return }
        presentation.fixedPortText = value
        presentation.draft.portPolicy.fixedPort = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        externalDraftPresentation = presentation
    }

    func setExternalDraftPortMode(_ mode: ExternalDraftPortMode) {
        guard var presentation = externalDraftPresentation else { return }
        presentation.draft.portPolicy.mode = mode
        if mode != .fixed {
            presentation.draft.portPolicy.fixedPort = nil
            presentation.fixedPortText = ""
        }
        if mode == .none { presentation.openInBrowser = false }
        externalDraftPresentation = presentation
    }

    func setExternalDraftArguments(_ value: String) {
        guard var presentation = externalDraftPresentation else { return }
        presentation.argumentsText = value
        presentation.draft.commandReviewComplete = false
        do {
            let arguments = try RuntimeArgumentParser.parse(value)
            presentation.draft.arguments = arguments
            markExternalDraftCommandEdited(&presentation.draft)
            presentation.argumentsError = nil
        } catch {
            // Keep the raw edit visible while quotes or escapes are incomplete. The last valid
            // structured argv remains untouched and Save stays disabled until parsing succeeds.
            presentation.argumentsError = error.localizedDescription
        }
        externalDraftPresentation = presentation
    }

    func setExternalDraftExecutable(_ value: String) {
        updateExternalDraft {
            $0.executable = value
            markExternalDraftCommandEdited(&$0)
        }
    }

    func setExternalDraftShellCommand(_ value: String) {
        updateExternalDraft {
            $0.shellCommand = value
            markExternalDraftCommandEdited(&$0)
        }
    }

    func setExternalDraftRunner(_ runner: ExternalDraftRunner) {
        updateExternalDraft {
            $0.runner = runner
            markExternalDraftCommandEdited(&$0)
        }
    }

    func setExternalDraftCommandReviewed(_ reviewed: Bool) {
        updateExternalDraft { $0.commandReviewComplete = reviewed }
    }

    func setExternalDraftOpenInBrowser(_ enabled: Bool) {
        guard var presentation = externalDraftPresentation else { return }
        presentation.openInBrowser = enabled
        externalDraftPresentation = presentation
    }

    func saveExternalLauncherDraft() async {
        guard let presentation = externalDraftPresentation,
              presentation.canSave,
              !isSavingExternalDraft else { return }
        isSavingExternalDraft = true
        defer { isSavingExternalDraft = false }

        let draft = presentation.draft
        let exposesHTTP = presentation.openInBrowser && draft.portPolicy.mode != .none
        let urlTemplate = exposesHTTP ? "http://${HOST}:${PORT}/" : nil
        let port: PortConfiguration
        switch draft.portPolicy.mode {
        case .automatic:
            port = PortConfiguration(mode: .automatic, URLTemplate: urlTemplate)
        case .fixed:
            port = PortConfiguration(
                mode: .fixed,
                fixedPort: draft.portPolicy.fixedPort,
                URLTemplate: urlTemplate
            )
        case .none:
            port = .none
        case .reviewRequired:
            setScopedAlertMessage(
                AlertMessage(
                    title: "Review port policy",
                    message: "Choose fresh managed, fixed, or no port before saving this launcher."
                ),
                for: presentation.id
            )
            return
        }

        let action = LaunchAction(
            name: "main",
            normalizedName: "main",
            description: presentation.origin == .externalObservation
                ? "Reviewed launch action from a separate process observation"
                : "Manually reviewed launch action",
            runner: draft.runner == .process ? .process : .shell,
            workingDirectory: ".",
            executable: draft.executable,
            arguments: draft.arguments,
            shellCommand: draft.shellCommand,
            port: port,
            openTarget: exposesHTTP ? .browser : .none
        )
        do {
            // The daemon owns project initialization and the generated read-only manifest.
            // This view model never writes launch_details.md or a project file itself.
            let project = try await client.initializeProject(directory: draft.projectDirectory)
            let detail = try await client.createLauncher(
                LauncherCreateRequest(
                    projectID: project.id,
                    name: draft.name,
                    description: draft.description,
                    runDetails: presentation.origin == .externalObservation
                        ? "Created from a separately observed listener. The original process remains separate and unmanaged."
                        : "Created from a manually reviewed launcher definition.",
                    tags: presentation.origin == .externalObservation ? ["observed"] : [],
                    primaryAction: action
                )
            )
            externalDraftPresentation = nil
            selectedExternalObservationID = nil
            selectedLauncherID = detail.id
            await refresh(silent: true)
        } catch {
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t save launcher draft", message: error.localizedDescription),
                for: presentation.id
            )
        }
    }

    private func markExternalDraftCommandEdited(_ draft: inout ExternalLauncherDraft) {
        switch draft.runner {
        case .process:
            draft.displayCommand = ShellEscaping.command(
                executable: draft.executable ?? "",
                arguments: draft.arguments
            )
        case .shell:
            draft.displayCommand = draft.shellCommand ?? ""
        }
        let commandValues = [draft.displayCommand, draft.executable, draft.shellCommand]
            .compactMap { $0 } + draft.arguments
        if !commandValues.contains(where: ExternalCommandRedactor.containsRedactionMarker) {
            // The replacement is now explicit user-entered text. The confirmation toggle below
            // remains false until the edited command has been reviewed.
            draft.sourceHadRedactions = false
            draft.sourceWasSanitized = false
        }
        draft.commandReviewComplete = false
    }

    func loadSessionOpenOptions(for session: SessionRecord, force: Bool = false) async {
        guard force || sessionOpenOptions[session.id] == nil,
              !loadingSessionOpenOptionIDs.contains(session.id) else { return }
        loadingSessionOpenOptionIDs.insert(session.id)
        defer { loadingSessionOpenOptionIDs.remove(session.id) }
        do {
            sessionOpenOptions[session.id] = try await client.sessionOpenOptions(sessionID: session.id)
            sessionOpenOptionErrors.removeValue(forKey: session.id)
        } catch {
            sessionOpenOptionErrors[session.id] = error.localizedDescription
        }
    }

    func openSessionOption(_ option: SessionOpenOption) async {
        guard !openingSessionOptionIDs.contains(option.id) else { return }
        openingSessionOptionIDs.insert(option.id)
        defer { openingSessionOptionIDs.remove(option.id) }
        do {
            let result = try await client.openSessionOption(sessionID: option.sessionID, optionID: option.id)
            alertMessage = AlertMessage(title: option.label, message: result.message)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t open \(option.label)", message: error.localizedDescription)
        }
    }

    func probeSessionOpenOption(_ option: SessionOpenOption) async {
        guard !probingSessionOptionIDs.contains(option.id) else { return }
        probingSessionOptionIDs.insert(option.id)
        defer { probingSessionOptionIDs.remove(option.id) }
        do {
            let result = try await client.probeSessionOpenOption(sessionID: option.sessionID, optionID: option.id)
            alertMessage = AlertMessage(title: "\(option.label) availability", message: result.message)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t probe \(option.label)", message: error.localizedDescription)
        }
    }

    func requestFocusSearch() {
        focusSearchRequest &+= 1
    }

    func requestLifecycleAction(for detail: LauncherDetail) async {
        let sessions = activeSessions(for: detail)
        if !sessions.isEmpty {
            requestClose(sessions: sessions, launcherName: detail.launcher.name)
        } else {
            await start(intent: LauncherStartIntent(
                detail: detail,
                rawRuntimeArguments: argumentsText(for: detail.launcher.id)
            ))
        }
    }

    func requestLaunchNew(for detail: LauncherDetail) {
        let intent = LauncherStartIntent(
            detail: detail,
            rawRuntimeArguments: argumentsText(for: detail.launcher.id),
            mode: .newInstance
        )
        Task { [weak self] in
            await self?.start(intent: intent)
        }
    }

    func requestLaunchSelected() {
        guard let detail = selectedDetail, activeSessions(for: detail).isEmpty else { return }
        // Capture both the exact launcher revision and its visible arguments before
        // scheduling. A polling refresh may reconcile selection before the Task runs.
        let intent = LauncherStartIntent(
            detail: detail,
            rawRuntimeArguments: argumentsText(for: detail.launcher.id)
        )
        Task { [weak self] in
            await self?.start(intent: intent)
        }
    }

    func requestCloseSelected() {
        guard let detail = selectedDetail,
              !activeSessions(for: detail).isEmpty else { return }
        requestClose(sessions: activeSessions(for: detail), launcherName: detail.launcher.name)
    }

    func requestRelaunchSelected() {
        guard let detail = selectedDetail else { return }
        requestRelaunch(detail: detail)
    }

    func requestRelaunch(detail: LauncherDetail) {
        guard let session = primaryActiveSession(for: detail),
              canRelaunch(session) else { return }
        requestRelaunch(detail: detail, session: session)
    }

    func requestRelaunch(detail: LauncherDetail, session: SessionRecord) {
        guard activeSession(id: session.id, for: detail)?.id == session.id,
              canRelaunch(session) else { return }
        let arguments: [String]
        do {
            if let explicitOverride = runtimeArgumentText[detail.launcher.id] {
                arguments = try RuntimeArgumentParser.parse(explicitOverride)
            } else {
                arguments = session.runtimeArguments
            }
        } catch {
            alertMessage = AlertMessage(title: "Check relaunch arguments", message: error.localizedDescription)
            return
        }
        guard let intent = LauncherRelaunchIntent(
            detail: detail,
            session: session,
            runtimeArguments: arguments
        ) else { return }
        relaunchConfirmation = RelaunchConfirmation(intent: intent)
    }

    func requestClose(session: SessionRecord, launcherName: String) {
        requestClose(sessions: [session], launcherName: launcherName)
    }

    func requestClose(sessions: [SessionRecord], launcherName: String) {
        let targets = sessions
            .filter(\.isActive)
            .map { session in
                let activeRuns = activeActionRuns(in: session)
                return CloseConfirmation.Target(
                    sessionID: session.id,
                    activeActionRunIDs: Set(activeRuns.map(\.id)),
                    serviceNames: activeRuns.map(\.actionName)
                )
            }
        guard !targets.isEmpty else { return }
        closeConfirmation = CloseConfirmation(
            launcherID: sessions[0].launcherID,
            launcherName: launcherName,
            targets: targets
        )
    }

    func confirmClose(_ confirmation: CloseConfirmation) async {
        closeConfirmation = nil

        guard let detail = launchers.first(where: { $0.launcher.id == confirmation.launcherID }),
              confirmation.targets.allSatisfy({ target in
                  guard let session = activeSession(id: target.sessionID, for: detail) else { return false }
                  return Set(activeActionRuns(in: session).map(\.id)) == target.activeActionRunIDs
              }) else {
            alertMessage = AlertMessage(
                title: "Active session changed",
                message: "An exact session or its active services changed. Review the current services before confirming CLOSE again."
            )
            await refresh(silent: true)
            return
        }

        let sessions = confirmation.targets.compactMap { activeSession(id: $0.sessionID, for: detail) }
        let sessionIDs = Set(sessions.map(\.id))
        stoppingSessionIDs.formUnion(sessionIDs)
        defer { stoppingSessionIDs.subtract(sessionIDs) }
        do {
            for session in sessions {
                let stopped = try await client.stopSession(id: session.id)
                if stopped.isActive {
                    transientSessions[stopped.id] = stopped
                    transientSessionDates[stopped.id] = Date()
                } else {
                    transientSessions.removeValue(forKey: stopped.id)
                    transientSessionDates.removeValue(forKey: stopped.id)
                }
            }
            await refresh(silent: true)
        } catch {
            let target = confirmation.closesAll ? "all \(confirmation.launcherName) sessions" : confirmation.launcherName
            alertMessage = AlertMessage(title: "Couldn’t close \(target)", message: error.localizedDescription)
            await refresh(silent: true)
        }
    }

    func confirmRelaunch(_ confirmation: RelaunchConfirmation) async {
        relaunchConfirmation = nil
        let intent = confirmation.intent

        guard let detail = launchers.first(where: { $0.launcher.id == intent.launcherID }),
              let session = activeSession(id: intent.expectedSessionID, for: detail),
              session.launcherRevision == intent.sessionLauncherRevision,
              detail.launcher.revision == intent.expectedLauncherRevision,
              activeServiceSnapshots(in: session) == intent.services.filter(\.isActive) else {
            alertMessage = AlertMessage(
                title: "Active session changed",
                message: "The exact session, its active services, or the launcher definition changed. Review the current state before confirming RELAUNCH again."
            )
            await refresh(silent: true)
            return
        }

        relaunchingSessionIDs.insert(session.id)
        defer { relaunchingSessionIDs.remove(session.id) }
        do {
            let result = try await client.relaunchSession(
                id: session.id,
                runtimeArguments: intent.runtimeArguments,
                openRequested: intent.openRequested,
                expectedLauncherRevision: intent.expectedLauncherRevision
            )
            guard result.session.launcherID == detail.launcher.id else {
                throw LauncherViewModelError.sessionMismatch
            }
            if result.session.isActive {
                transientSessions[result.session.id] = result.session
                transientSessionDates[result.session.id] = Date()
            } else {
                transientSessions.removeValue(forKey: result.session.id)
                transientSessionDates.removeValue(forKey: result.session.id)
            }
            runtimeArgumentText.removeValue(forKey: detail.launcher.id)
            await refresh(silent: true)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t relaunch \(confirmation.launcherName)", message: error.localizedDescription)
            await refresh(silent: true)
        }
    }

    func presentSkillInstaller() {
        isSkillInstallerPresented = true
    }

    func refreshLauncherSkillStatus(
        silent: Bool = false,
        presenterID: UUID? = nil
    ) async {
        skillStatusRequestGeneration &+= 1
        let generation = skillStatusRequestGeneration
        if !silent { isRefreshingSkillStatus = true }
        defer {
            if !silent { isRefreshingSkillStatus = false }
        }
        do {
            let status = try await client.launcherSkillStatus()
            guard generation == skillStatusRequestGeneration else { return }
            launcherSkillStatus = status
            launcherSkillStatusError = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            guard generation == skillStatusRequestGeneration else { return }
            launcherSkillStatusError = error.localizedDescription
            if !silent {
                let message = AlertMessage(title: "Skill status unavailable", message: error.localizedDescription)
                if let presenterID {
                    setScopedAlertMessage(message, for: presenterID)
                } else {
                    alertMessage = message
                }
            }
        }
    }

    func installLauncherSkill(
        for host: LauncherSkillHost,
        presenterID: UUID
    ) async {
        guard !isInstallingSkill(for: host),
              skillUninstallPresentation == nil,
              !isPreparingSkillUninstall,
              !isUninstallingSkill,
              skillStatus(for: host)?.surfaces.contains(where: \.available) == true else { return }
        installingSkillHosts.insert(host)
        defer { installingSkillHosts.remove(host) }
        do {
            let result = try await client.installLauncherSkill(for: host)
            await refreshLauncherSkillStatus(silent: true)
            setScopedAlertMessage(
                AlertMessage(
                    title: "Installed for \(host.displayName)",
                    message: skillInstallSuccessMessage(result, host: host)
                ),
                for: presenterID
            )
        } catch {
            setScopedAlertMessage(
                AlertMessage(
                    title: "Couldn’t install for \(host.displayName)",
                    message: error.localizedDescription
                ),
                for: presenterID
            )
            await refreshLauncherSkillStatus(silent: true)
        }
    }

    func requestSkillUninstall(
        for host: LauncherSkillHost,
        presenterID: UUID
    ) async {
        guard skillStatus(for: host)?.canUninstall == true,
              skillUninstallPresentation == nil,
              !isInstallingAnySkill,
              !isPreparingSkillUninstall,
              !isUninstallingSkill else { return }
        skillUninstallRequestGeneration += 1
        let generation = skillUninstallRequestGeneration
        skillUninstallPreparingPresenterID = presenterID
        isPreparingSkillUninstall = true
        defer {
            if skillUninstallRequestGeneration == generation {
                skillUninstallPreparingPresenterID = nil
                isPreparingSkillUninstall = false
            }
        }
        do {
            let intent = try await client.prepareLauncherSkillUninstall(for: host)
            guard skillUninstallRequestGeneration == generation,
                  activeScopedAlertPresenterIDs.contains(presenterID),
                  skillUninstallPresentation == nil else { return }
            skillUninstallPresentation = SkillUninstallPresentation(
                presenterID: presenterID,
                intent: intent
            )
        } catch {
            guard skillUninstallRequestGeneration == generation else { return }
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t prepare skill uninstall", message: error.localizedDescription),
                for: presenterID
            )
            await refreshLauncherSkillStatus(silent: true)
        }
    }

    func confirmSkillUninstall(_ presentation: SkillUninstallPresentation) async {
        guard let current = skillUninstallPresentation,
              current.id == presentation.id,
              current.presenterID == presentation.presenterID,
              current.intent == presentation.intent,
              current.confirmationText == presentation.confirmationText,
              presentation.confirmationText == presentation.intent.confirmationText,
              !isUninstallingSkill else { return }
        isUninstallingSkill = true
        defer { isUninstallingSkill = false }
        // The daemon capability is single-use. Close this confirmation immediately so any
        // failure is retried only through a fresh inspection and warning.
        skillUninstallPresentation = nil
        do {
            let result = try await client.uninstallLauncherSkill(
                intent: presentation.intent,
                confirmationText: presentation.confirmationText
            )
            setScopedAlertMessage(
                AlertMessage(title: "Skill uninstalled", message: result.result.message),
                for: presentation.presenterID
            )
            await refreshLauncherSkillStatus(silent: true)
        } catch {
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t uninstall skill", message: error.localizedDescription),
                for: presentation.presenterID
            )
            await refreshLauncherSkillStatus(silent: true)
        }
    }

    func cancelSkillUninstall(_ presentation: SkillUninstallPresentation) {
        guard let current = skillUninstallPresentation,
              current.id == presentation.id,
              current.presenterID == presentation.presenterID,
              current.intent == presentation.intent else { return }
        skillUninstallPresentation = nil
    }

    private func skillInstallSuccessMessage(
        _ result: LauncherSkillInstallResult,
        host: LauncherSkillHost
    ) -> String {
        let verification = "Launcher verified the exact managed files at \(result.sharedInstallationPath). Desktop and CLI share this one installation for \(host.displayName)."
        let discovery: String
        switch host {
        case .codex:
            discovery = result.restartRecommended
                ? "Codex normally detects skill changes automatically. Restart only if the newly installed skill is still missing."
                : "Codex detects this skill change automatically; no restart is expected."
        case .claudeCode:
            discovery = result.restartRecommended
                ? "Restart Claude because its top-level skills directory was created during installation."
                : "Claude detects this change live because its top-level skills directory already existed."
        }
        return "\(verification) \(discovery)"
    }

    func downloadLauncherSkill(presenterID: UUID) async {
        guard !isDownloadingSkill else { return }
        isDownloadingSkill = true
        defer { isDownloadingSkill = false }
        do {
            let source = try await client.launcherSkillSource()
            let panel = NSSavePanel()
            panel.title = "Download Launch Station Skill"
            panel.message = "Choose where to save the canonical SKILL.md file."
            panel.prompt = "Save Skill"
            panel.nameFieldStringValue = source.fileName
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try source.contents.write(to: destination, atomically: true, encoding: .utf8)
            setScopedAlertMessage(
                AlertMessage(
                    title: "SKILL.md saved",
                    message: "Saved Launch Station skill \(source.version) to \(destination.path)."
                ),
                for: presenterID
            )
        } catch {
            setScopedAlertMessage(
                AlertMessage(title: "Couldn’t download SKILL.md", message: error.localizedDescription),
                for: presenterID
            )
        }
    }

    func argumentsText(for launcherID: UUID) -> String {
        runtimeArgumentText[launcherID, default: ""]
    }

    func setArgumentsText(_ value: String, for launcherID: UUID) {
        runtimeArgumentText[launcherID] = value
    }

    func reveal(_ project: ProjectRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.directory, isDirectory: true)])
    }

    func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func openEndpoint(_ value: String) {
        guard let url = URL(string: value), url.scheme != nil else {
            alertMessage = AlertMessage(title: "Endpoint unavailable", message: "The launcher returned an invalid endpoint: \(value)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func showLog(for session: SessionRecord, launcherName: String) async {
        let presentation = LogPresentation(sessionID: session.id, launcherName: launcherName)
        logPresentation = presentation
        do {
            let response = try await client.sessionLog(sessionID: session.id)
            guard logPresentation?.id == presentation.id else { return }
            logPresentation?.text = response.text
            logPresentation?.diagnoses = response.diagnoses
            logPresentation?.isLoading = false
        } catch {
            guard logPresentation?.id == presentation.id else { return }
            logPresentation?.isLoading = false
            logPresentation?.errorMessage = error.localizedDescription
        }
    }

    func presentHistory(for detail: LauncherDetail? = nil, selectedSession: SessionRecord? = nil) {
        let presentation = HistoryPresentation(
            launcherID: detail?.launcher.id,
            selectedSession: selectedSession
        )
        historyPresentation = presentation
        Task { [weak self] in
            await self?.loadHistory(presentationID: presentation.id, reset: true)
        }
    }

    func loadMoreHistory() async {
        guard let presentation = historyPresentation,
              presentation.nextCursor != nil,
              !presentation.isLoadingMore else { return }
        await loadHistory(presentationID: presentation.id, reset: false)
    }

    func loadRecentManagedLaunches() async {
        guard !isLoadingRecentHistory else { return }
        isLoadingRecentHistory = true
        defer { isLoadingRecentHistory = false }
        do {
            let page = try await client.sessionHistory(limit: 12)
            recentSessions = page.sessions
        } catch {
            // The compact focused-search affordance is supplementary. The normal
            // connection alert remains reserved for catalog operations.
            recentSessions = []
        }
    }

    func loadRecentManagedLaunchesIfNeeded() {
        // Refresh whenever an empty search field receives focus. Session state can change
        // naturally while the app remains open, so a once-per-process cache would make the
        // "recent launches" surface stale for the rest of the GUI session.
        guard !isLoadingRecentHistory else { return }
        Task { [weak self] in
            await self?.loadRecentManagedLaunches()
        }
    }

    private func start(intent: LauncherStartIntent) async {
        let detail = intent.detail
        switch intent.mode {
        case .reusePrimary:
            guard activeSessions(for: detail).contains(where: { $0.launchRole == .primary }) == false,
                  !startingLauncherIDs.contains(detail.launcher.id) else { return }
        case .newInstance:
            guard !startingAdditionalLauncherIDs.contains(detail.launcher.id) else { return }
        }

        let arguments: [String]
        do {
            arguments = try RuntimeArgumentParser.parse(intent.rawRuntimeArguments)
        } catch {
            alertMessage = AlertMessage(title: "Check launch arguments", message: error.localizedDescription)
            return
        }

        switch intent.mode {
        case .reusePrimary:
            startingLauncherIDs.insert(detail.launcher.id)
        case .newInstance:
            startingAdditionalLauncherIDs.insert(detail.launcher.id)
        }
        defer {
            switch intent.mode {
            case .reusePrimary:
                startingLauncherIDs.remove(detail.launcher.id)
            case .newInstance:
                startingAdditionalLauncherIDs.remove(detail.launcher.id)
            }
        }
        do {
            let session = try await client.startLauncher(
                id: detail.launcher.id,
                runtimeArguments: arguments,
                openRequested: intent.openRequested,
                expectedLauncherRevision: intent.expectedLauncherRevision,
                mode: intent.mode
            )
            if session.launcherID != detail.launcher.id {
                throw LauncherViewModelError.sessionMismatch
            }
            if session.isActive {
                transientSessions[session.id] = session
                transientSessionDates[session.id] = Date()
            }
            runtimeArgumentText.removeValue(forKey: detail.launcher.id)
            await refresh(silent: true)
        } catch {
            alertMessage = AlertMessage(title: "Couldn’t launch \(detail.launcher.name)", message: error.localizedDescription)
            await refresh(silent: true)
        }
    }

    private func reconcileSelection(with catalog: CatalogSnapshot) {
        // Keep a currently selected external listener authoritative through catalog polling.
        // Its own listener refresh clears the ID only when that exact process disappears, at
        // which point this method immediately chooses the managed fallback.
        guard selectedExternalObservationID == nil else { return }
        if let selectedLauncherID,
           catalog.launchers.contains(where: { $0.id == selectedLauncherID }) {
            return
        }
        selectedLauncherID = catalog.launchers
            .sorted(by: launcherSort)
            .first(where: { !activeSessions(for: $0).isEmpty })?.id
            ?? catalog.launchers.sorted(by: launcherSort).first?.id
    }

    private func reconcileTransientSessions(with catalog: CatalogSnapshot) {
        let now = Date()
        var active = [UUID: SessionRecord]()
        for detail in catalog.launchers {
            let serverSessions = detail.activeSessions.isEmpty
                ? [detail.activeSession].compactMap { $0 }
                : detail.activeSessions
            for session in serverSessions where session.isActive {
                active[session.id] = session
            }
        }

        for (sessionID, session) in active {
            transientSessions[sessionID] = session
            transientSessionDates[sessionID] = now
        }

        for sessionID in Array(transientSessions.keys) where active[sessionID] == nil {
            let transient = transientSessions[sessionID]
            let detail = catalog.launchers.first(where: { $0.launcher.id == transient?.launcherID })
            let serverObservedEnd = detail?.lastSession?.id == transient?.id && detail?.lastSession?.isActive == false
            let age = now.timeIntervalSince(transientSessionDates[sessionID] ?? .distantPast)
            if serverObservedEnd || age > 5 {
                transientSessions.removeValue(forKey: sessionID)
                transientSessionDates.removeValue(forKey: sessionID)
            }
        }
    }

    private func loadHistory(presentationID: UUID, reset: Bool) async {
        guard var presentation = historyPresentation, presentation.id == presentationID else { return }
        if reset {
            presentation.isLoading = true
            presentation.errorMessage = nil
        } else {
            presentation.isLoadingMore = true
        }
        historyPresentation = presentation

        do {
            let page = try await client.sessionHistory(
                launcherID: presentation.launcherID,
                limit: 50,
                cursor: reset ? nil : presentation.nextCursor
            )
            guard var current = historyPresentation, current.id == presentationID else { return }
            let sessions = reset ? page.sessions : current.sessions + page.sessions
            current.sessions = Array(Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { newer, _ in newer }).values)
                .sorted { $0.startedAt > $1.startedAt }
            current.selectedSessionID = current.selectedSessionID ?? current.sessions.first?.id
            current.nextCursor = page.nextCursor
            current.isLoading = false
            current.isLoadingMore = false
            current.errorMessage = nil
            historyPresentation = current
        } catch {
            guard var current = historyPresentation, current.id == presentationID else { return }
            current.isLoading = false
            current.isLoadingMore = false
            current.errorMessage = error.localizedDescription
            historyPresentation = current
        }
    }

    private func activeActionRuns(in session: SessionRecord) -> [ActionRunRecord] {
        session.actionRuns.filter {
            $0.state == .starting || $0.state == .running || $0.state == .stopping
        }
    }

    private func activeServiceSnapshots(in session: SessionRecord) -> [LauncherServiceIdentitySnapshot] {
        activeActionRuns(in: session).map(LauncherServiceIdentitySnapshot.init(actionRun:))
    }

    private func launcherSort(_ lhs: LauncherDetail, _ rhs: LauncherDetail) -> Bool {
        let lhsActive = activeSession(for: lhs) != nil
        let rhsActive = activeSession(for: rhs) != nil
        if lhsActive != rhsActive { return lhsActive && !rhsActive }
        return alphabeticalLauncherSort(lhs, rhs)
    }

    private func displayedLaunchers(sortedBy requestedOrder: LauncherListSortOrder) -> [LauncherDetail] {
        let hasSearchQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let order = hasSearchQuery ? LauncherListSortOrder.alphabetical : requestedOrder
        return filteredLaunchers.sorted { lhs, rhs in
            guard order == .recentlyRun else {
                return alphabeticalLauncherSort(lhs, rhs)
            }

            let lhsDate = mostRecentLaunchDate(for: lhs)
            let rhsDate = mostRecentLaunchDate(for: rhs)
            if lhsDate != rhsDate {
                switch (lhsDate, rhsDate) {
                case let (.some(lhsDate), .some(rhsDate)):
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }
            }
            return alphabeticalLauncherSort(lhs, rhs)
        }
    }

    private func mostRecentLaunchDate(for detail: LauncherDetail) -> Date? {
        let activeDates = activeSessions(for: detail).map(\.startedAt)
        return (activeDates + [detail.lastSession?.startedAt].compactMap { $0 }).max()
    }

    private func alphabeticalLauncherSort(_ lhs: LauncherDetail, _ rhs: LauncherDetail) -> Bool {
        let comparison = lhs.launcher.name.localizedStandardCompare(rhs.launcher.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func sessionSort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.launchRole != rhs.launchRole { return lhs.launchRole == .primary }
        return lhs.startedAt > rhs.startedAt
    }
}

private enum LauncherViewModelError: LocalizedError {
    case sessionMismatch

    var errorDescription: String? {
        "The launcher service returned a session for a different launcher. Nothing was marked active locally."
    }
}

private enum RuntimeArgumentParser {
    private enum Quote {
        case single
        case double
    }

    enum ParseError: LocalizedError {
        case unterminatedQuote
        case danglingEscape

        var errorDescription: String? {
            switch self {
            case .unterminatedQuote:
                return "A quoted runtime argument is missing its closing quote."
            case .danglingEscape:
                return "The runtime arguments end with an incomplete escape."
            }
        }
    }

    static func parse(_ source: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false
        var hasToken = false

        func appendCurrent() {
            guard hasToken else { return }
            result.append(current)
            current = ""
            hasToken = false
        }

        for character in source {
            if escaping {
                current.append(character)
                hasToken = true
                escaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasToken = true
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    escaping = true
                } else {
                    current.append(character)
                }
                hasToken = true
            case nil:
                if character == "'" {
                    quote = .single
                    hasToken = true
                } else if character == "\"" {
                    quote = .double
                    hasToken = true
                } else if character == "\\" {
                    escaping = true
                    hasToken = true
                } else if character.isWhitespace {
                    appendCurrent()
                } else {
                    current.append(character)
                    hasToken = true
                }
            }
        }

        if escaping { throw ParseError.danglingEscape }
        if quote != nil { throw ParseError.unterminatedQuote }
        appendCurrent()
        return result
    }
}
