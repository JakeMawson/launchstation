import AppKit
import LauncherCore
import SwiftUI

enum RunwayPalette {
    static let porcelain = adaptive(light: 0xFBFCFC, dark: 0x151D20)
    static let fog = adaptive(light: 0xEEF2F3, dark: 0x1C272B)
    static let carbon = adaptive(light: 0x172126, dark: 0x0E1518)
    static let carbonText = adaptive(light: 0x172126, dark: 0xECF2F2)
    static let secondaryText = adaptive(light: 0x5B686D, dark: 0xAAB7BB)
    static let tide = adaptive(light: 0x276675, dark: 0x68A9B6)
    static let ignition = adaptive(light: 0xC94B2C, dark: 0xED7657)
    static let relay = adaptive(light: 0x24795F, dark: 0x55B493)
    static let railText = Color(red: 0.91, green: 0.95, blue: 0.95)
    static let railMuted = Color(red: 0.61, green: 0.69, blue: 0.71)
    static let divider = adaptive(light: 0xD8DFE1, dark: 0x334146)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        let color = NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return nsColor(hex: match == .darkAqua ? dark : light)
        }
        return Color(nsColor: color)
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
private func scopedAlertBinding(
    viewModel: LauncherViewModel,
    presenterID: UUID
) -> Binding<LauncherViewModel.AlertMessage?> {
    Binding(
        get: { viewModel.scopedAlertMessage(for: presenterID) },
        set: { viewModel.setScopedAlertMessage($0, for: presenterID) }
    )
}

struct LauncherRootView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @FocusState private var searchFocused: Bool
    // Start in the visible state instead of asking AppKit to animate the sidebar in just after
    // launch. That initial detail-only-to-all transition was both visually jarring and delayed
    // access to the running / separately-started lists.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var rootLogPresentation: Binding<LauncherViewModel.LogPresentation?> {
        Binding(
            get: {
                viewModel.historyPresentation == nil ? viewModel.logPresentation : nil
            },
            set: { value in
                if viewModel.historyPresentation == nil || value == nil {
                    viewModel.logPresentation = value
                }
            }
        )
    }

    /// SwiftUI rebuilds the primary toolbar item whenever the saved/external selection changes.
    /// Pass that identity through to the AppKit spacer installer so it corrects the new item order
    /// instead of relying on the initial toolbar composition.
    private var toolbarAlignmentToken: String {
        if let detail = viewModel.selectedDetail { return "launcher:\(detail.id.uuidString)" }
        if let observation = viewModel.selectedExternalObservation { return "external:\(observation.id.uuidString)" }
        return "none"
    }

    private var rootHasActiveSheet: Bool {
        viewModel.historyPresentation != nil
            || viewModel.isSkillInstallerPresented
            || viewModel.externalClosePresentation != nil
            || viewModel.externalDraftPresentation != nil
            || viewModel.launcherEditPresentation != nil
            || (viewModel.logPresentation != nil && viewModel.historyPresentation == nil)
    }

    private var rootAlertPresentation: Binding<LauncherViewModel.AlertMessage?> {
        Binding(
            get: { rootHasActiveSheet ? nil : viewModel.alertMessage },
            set: { value in
                if let value {
                    guard !rootHasActiveSheet else { return }
                    viewModel.alertMessage = value
                } else if !rootHasActiveSheet {
                    // Do not discard a root alert merely because a sheet temporarily made this
                    // binding read as nil. It remains queued until the root can present it.
                    viewModel.alertMessage = nil
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var launcherToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            launcherTitleToolbarItem.sharedBackgroundVisibility(.hidden)
            launcherActionToolbarItem.sharedBackgroundVisibility(.hidden)
        } else {
            launcherTitleToolbarItem
            launcherActionToolbarItem
        }
    }

    private var launcherTitleToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text("Launch Station")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 18)
        }
    }

    private var launcherActionToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 10) {
                if let detail = viewModel.selectedDetail {
                    Button {
                        viewModel.presentLauncherEditor(for: detail)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("EDIT")
                        }
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.35)
                        .fixedSize()
                    }
                    .help("Edit this saved launcher")
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(detail.launcher.name)")
                    .accessibilityHint("Opens the saved launcher properties and action commands. Changes apply to future launches only.")
                } else if let observation = viewModel.selectedExternalObservation {
                    Button {
                        Task { await viewModel.requestExternalLauncherDraft(for: observation) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.rectangle.on.rectangle")
                            Text(viewModel.isLoadingExternalDraft ? "PREPARING…" : "ADD")
                        }
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.35)
                        .fixedSize()
                    }
                    .disabled(viewModel.isLoadingExternalDraft)
                    .help("Add a reviewed launcher from this separately started process")
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add launcher from external listener PID \(observation.pid)")
                    .accessibilityHint("Opens the existing reviewed launcher draft and does not adopt the running process.")
                }

                Button {
                    viewModel.presentManualLauncherDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add launcher")
                .buttonStyle(.plain)
                .accessibilityLabel("Add launcher")
                .accessibilityHint("Opens a blank manual launcher definition. Nothing is saved until reviewed and confirmed.")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                LauncherSidebar(
                    viewModel: viewModel,
                    searchFocused: $searchFocused,
                    onExitSearch: exitSearch
                )
                    .navigationSplitViewColumnWidth(min: 270, ideal: 292, max: 340)
            } detail: {
                Group {
                    if let observation = viewModel.selectedExternalObservation {
                        ExternalProcessInspector(viewModel: viewModel, observation: observation)
                            .id(observation.id)
                    } else if let detail = viewModel.selectedDetail {
                        LauncherInspector(viewModel: viewModel, detail: detail)
                            .id(detail.id)
                    } else {
                        EmptyInspector(isLoading: viewModel.isInitialLoading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RunwayPalette.porcelain)
            }
            .navigationSplitViewStyle(.balanced)

            Divider()
            LauncherStatusBar(viewModel: viewModel)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(RunwayPalette.porcelain)
        .overlay {
            if viewModel.isStartingService {
                StartingServiceOverlay()
            }
        }
        .toolbar {
            launcherToolbar
        }
        .background(ToolbarTrailingActionSpacerInstaller(configurationToken: toolbarAlignmentToken))
        .task {
            viewModel.startPolling()
            // With the sidebar visible at launch AppKit otherwise promotes its first text field
            // to first responder. That hid the normal Running / Started Separately sections
            // behind the recent-search state on every fresh launch.
            await Task.yield()
            searchFocused = false
        }
        .onDisappear { viewModel.stopPolling() }
        .onChange(of: viewModel.focusSearchRequest) { _ in
            columnVisibility = .all
            Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard columnVisibility != .detailOnly else { return }
                searchFocused = true
            }
        }
        .onChange(of: viewModel.selectedLauncherID) { selectedLauncherID in
            if selectedLauncherID != nil {
                viewModel.selectedExternalObservationID = nil
            }
        }
        .alert(item: rootAlertPresentation) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Close active session?",
            isPresented: Binding(
                get: { viewModel.closeConfirmation != nil },
                set: { if !$0 { viewModel.closeConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.closeConfirmation
        ) { confirmation in
            Button(role: .destructive) {
                Task { await viewModel.confirmClose(confirmation) }
            } label: {
                Text(confirmation.buttonTitle)
            }
            Button("Cancel", role: .cancel) {
                viewModel.closeConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .confirmationDialog(
            "Relaunch active session?",
            isPresented: Binding(
                get: { viewModel.relaunchConfirmation != nil },
                set: { if !$0 { viewModel.relaunchConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.relaunchConfirmation
        ) { confirmation in
            Button("Relaunch \(confirmation.launcherName)") {
                Task { await viewModel.confirmRelaunch(confirmation) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.relaunchConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(item: rootLogPresentation) { initial in
            LauncherLogSheet(viewModel: viewModel, initial: initial)
        }
        .sheet(item: $viewModel.historyPresentation) { initial in
            LauncherHistorySheet(viewModel: viewModel, initial: initial)
        }
        .sheet(isPresented: $viewModel.isSkillInstallerPresented) {
            SkillInstallerSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.externalClosePresentation) { initial in
            ExternalCloseSheet(viewModel: viewModel, initial: initial)
        }
        .sheet(item: $viewModel.externalDraftPresentation) { initial in
            ExternalLauncherDraftSheet(viewModel: viewModel, initial: initial)
        }
        .sheet(item: $viewModel.launcherEditPresentation) { initial in
            LauncherEditorSheet(viewModel: viewModel, initial: initial)
        }
    }

    private func exitSearch() {
        viewModel.searchText = ""
        searchFocused = false
    }
}

private struct StartingServiceOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(RunwayPalette.tide)

                Text("Starting background process…")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))

                Text("Launcher is restoring its local service.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(RunwayPalette.carbonText)
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .background(RunwayPalette.fog, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(RunwayPalette.divider.opacity(0.8), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Starting background process")
            .accessibilityHint("Launcher is restoring its local service. Please wait.")
        }
        .contentShape(Rectangle())
    }
}

struct LauncherCommands: Commands {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some Commands {
        CommandMenu("Launcher") {
            Button("Find Launcher") {
                viewModel.requestFocusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Launch Selected") {
                viewModel.requestLaunchSelected()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canLaunchSelected)

            Button("Close Selected Session") {
                viewModel.requestCloseSelected()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!viewModel.canStopSelected)

            Button("Relaunch Selected") {
                viewModel.requestRelaunchSelected()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!viewModel.canRelaunchSelected)

            Button("Managed Launch History") {
                viewModel.presentHistory()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("Install Agent Skill…") {
                viewModel.presentSkillInstaller()
            }

            Divider()

            Button("Refresh Launchers") {
                Task { await viewModel.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Refresh External Listeners") {
                Task { await viewModel.refreshExternalProcesses(fresh: true) }
            }
        }
    }
}

private struct LauncherSidebar: View {
    @ObservedObject var viewModel: LauncherViewModel
    var searchFocused: FocusState<Bool>.Binding
    var onExitSearch: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("launcherListSortOrder") private var sortOrder = LauncherListSortOrder.alphabetical
    @State private var isRunningExpanded = true
    @State private var isExternalExpanded = true
    @State private var isAllLaunchersExpanded = true

    private var isSearching: Bool {
        searchFocused.wrappedValue
            || !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsRecentManagedLaunches: Bool {
        searchFocused.wrappedValue
            && viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                SearchField(
                    text: $viewModel.searchText,
                    isFocused: searchFocused,
                    onExit: onExitSearch
                )
                .frame(maxWidth: .infinity)

                if !isSearching {
                    LauncherSortToggle(order: $sortOrder, reduceMotion: reduceMotion)
                        .transition(
                            .opacity.combined(
                                with: .scale(scale: 0.82, anchor: .trailing)
                            )
                        )
                }
            }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSearching)

            if viewModel.shouldShowSkillPrompt {
                SkillPromptCard(viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }

            List(selection: $viewModel.selectedLauncherID) {
                if showsRecentManagedLaunches {
                    Section("Recent managed launches") {
                        if viewModel.isLoadingRecentHistory {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading recent launches…")
                            }
                            .foregroundStyle(RunwayPalette.secondaryText)
                        } else if viewModel.recentSessions.isEmpty {
                            Text("No managed launches yet")
                                .foregroundStyle(RunwayPalette.secondaryText)
                        } else {
                            ForEach(viewModel.recentSessions) { session in
                                Button {
                                    viewModel.selectManagedLauncher(session.launcherID)
                                } label: {
                                    RecentSessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Section {
                        if isRunningExpanded {
                            if viewModel.runningLaunchers(sortedBy: sortOrder).isEmpty {
                                Text(viewModel.searchText.isEmpty ? "No active managed launchers" : "No running matches")
                                    .foregroundStyle(RunwayPalette.secondaryText)
                            } else {
                                ForEach(viewModel.runningLaunchers(sortedBy: sortOrder)) { detail in
                                    LauncherRow(
                                        detail: detail,
                                        session: viewModel.activeSession(for: detail),
                                        isStarting: viewModel.startingLauncherIDs.contains(detail.id)
                                    )
                                    .tag(detail.id)
                                    .simultaneousGesture(TapGesture().onEnded {
                                        viewModel.selectManagedLauncher(detail.id)
                                    })
                                }
                            }
                            SidebarDisclosureHeader(
                                title: "Started Separately",
                                isExpanded: $isExternalExpanded,
                                accent: RunwayPalette.ignition
                            )
                            .listRowBackground(Color.clear)

                            if isExternalExpanded {
                                if viewModel.isRefreshingExternalProcesses && viewModel.externalProcessSnapshot == nil {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Inspecting other listeners…")
                                    }
                                    .foregroundStyle(RunwayPalette.secondaryText)
                                } else if let error = viewModel.externalProcessError,
                                          viewModel.externalProcessSnapshot == nil {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Listener inspection unavailable")
                                            .foregroundStyle(Color(nsColor: .systemOrange))
                                        Text(error)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(RunwayPalette.secondaryText)
                                            .lineLimit(2)
                                        Button("Retry") {
                                            Task { await viewModel.refreshExternalProcesses(fresh: true) }
                                        }
                                        .buttonStyle(.link)
                                    }
                                } else if viewModel.observedExternalProcesses.isEmpty {
                                    Text(viewModel.searchText.isEmpty ? "No separately started listeners" : "No separate listener matches")
                                        .foregroundStyle(RunwayPalette.secondaryText)
                                } else {
                                    ForEach(viewModel.observedExternalProcesses) { observation in
                                        Button {
                                            viewModel.selectExternalProcess(observation)
                                        } label: {
                                            ExternalProcessRow(
                                                observation: observation,
                                                selected: viewModel.selectedExternalObservationID == observation.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("External listener PID \(observation.pid), \(observation.command.displayCommand)")
                                        .accessibilityHint("Shows this separately observed listener and clears any managed launcher row selection.")
                                    }
                                }
                            }
                        }
                    } header: {
                        SidebarDisclosureHeader(title: "Running", isExpanded: $isRunningExpanded)
                    }

                    Section {
                        if isAllLaunchersExpanded {
                            if viewModel.nonRunningLaunchers(sortedBy: sortOrder).isEmpty {
                                Text(viewModel.searchText.isEmpty ? "No inactive launchers" : "No additional matches")
                                    .foregroundStyle(RunwayPalette.secondaryText)
                            } else {
                            ForEach(viewModel.nonRunningLaunchers(sortedBy: sortOrder)) { detail in
                                LauncherRow(
                                    detail: detail,
                                    session: viewModel.activeSession(for: detail),
                                    isStarting: viewModel.startingLauncherIDs.contains(detail.id)
                                )
                                .tag(detail.id)
                                .simultaneousGesture(TapGesture().onEnded {
                                    viewModel.selectManagedLauncher(detail.id)
                                })
                            }
                            }
                        }
                    } header: {
                        SidebarDisclosureHeader(title: "All launchers", isExpanded: $isAllLaunchersExpanded)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tracklessOverlayScroller()
            .background(RunwayPalette.fog)
            .overlay {
                if viewModel.isInitialLoading {
                    ProgressView("Loading launchers…")
                        .controlSize(.small)
                        .foregroundStyle(RunwayPalette.secondaryText)
                } else if !showsRecentManagedLaunches
                    && viewModel.filteredLaunchers.isEmpty
                    && viewModel.observedExternalProcesses.isEmpty
                    && !viewModel.isRefreshingExternalProcesses
                    && viewModel.externalProcessError == nil {
                    SidebarEmptyState(hasQuery: !viewModel.searchText.isEmpty) {
                        viewModel.searchText = ""
                    }
                }
            }
        }
        .background(RunwayPalette.fog)
        .onChange(of: searchFocused.wrappedValue) { focused in
            if focused && viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.loadRecentManagedLaunchesIfNeeded()
            }
        }
        .onChange(of: viewModel.searchText) { query in
            if searchFocused.wrappedValue && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.loadRecentManagedLaunchesIfNeeded()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Launcher list")
    }
}

private struct LauncherSortToggle: View {
    @Binding var order: LauncherListSortOrder
    var reduceMotion: Bool
    @State private var isHovered = false

    private var modeName: String {
        order == .alphabetical ? "Alphabetical" : "Most recently run"
    }

    private var nextModeName: String {
        order == .alphabetical ? "most recently run" : "alphabetical"
    }

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                order.toggle()
            }
        } label: {
            ZStack {
                if order == .alphabetical {
                    Text("A–Z")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(-0.2)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    Image(systemName: "stopwatch")
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .foregroundStyle(isHovered ? RunwayPalette.tide : RunwayPalette.secondaryText)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(RunwayPalette.porcelain)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isHovered ? RunwayPalette.tide : RunwayPalette.divider, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Launcher order: \(modeName). Click for \(nextModeName).")
        .accessibilityLabel("Launcher order")
        .accessibilityValue(modeName)
        .accessibilityHint("Changes launcher order to \(nextModeName).")
    }
}

private struct SidebarDisclosureHeader: View {
    var title: String
    @Binding var isExpanded: Bool
    var accent: Color = RunwayPalette.secondaryText

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityHint("Toggles the \(title.lowercased()) list.")
    }
}

private struct RecentSessionRow: View {
    var session: SessionRecord

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: SessionVisualState(session: session).symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SessionVisualState(session: session).color)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.launcherName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(session.launchRole.rawValue.uppercased()) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SessionVisualState(session: session).label), recent \(session.launcherName), \(session.launchRole.rawValue)")
    }
}

private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onExit: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(RunwayPalette.secondaryText)
                .accessibilityHidden(true)

            TextField("Search launchers", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onExitCommand(perform: onExit)
                .accessibilityLabel("Search launchers by name, project, or tag")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RunwayPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(RunwayPalette.porcelain)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isFocused.wrappedValue ? RunwayPalette.tide : RunwayPalette.divider, lineWidth: isFocused.wrappedValue ? 2 : 1)
                )
        )
    }
}

private struct SidebarEmptyState: View {
    var hasQuery: Bool
    var clear: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hasQuery ? "magnifyingglass" : "command.square")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(RunwayPalette.secondaryText)
            Text(hasQuery ? "No matching launchers" : "No launchers registered")
                .font(.system(size: 13, weight: .semibold))
            Text(hasQuery ? "Try a different name or tag." : "Use launch --create in a project directory.")
                .font(.caption)
                .foregroundStyle(RunwayPalette.secondaryText)
                .multilineTextAlignment(.center)
            if hasQuery {
                Button("Clear search", action: clear)
                    .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RunwayPalette.fog)
    }
}

private struct SkillPromptCard: View {
    @ObservedObject var viewModel: LauncherViewModel
    @State private var hovered = false

    var body: some View {
        Button {
            viewModel.presentSkillInstaller()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.square.filled.on.square")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 31, height: 31)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("INSTALL AGENT SKILL")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.7)
                    Text("Teach your coding agents to register and relaunch projects here.")
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .padding(11)
            .background(
                LinearGradient(
                    colors: [RunwayPalette.tide, RunwayPalette.relay],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(hovered ? 0.9 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Install or download the Launch Station agent skill")
        .accessibilityLabel("Install Launch Station agent skill")
        .accessibilityHint("Opens choices for Codex, Claude Code, or downloading SKILL.md.")
    }
}

private struct LauncherRow: View {
    var detail: LauncherDetail
    var session: SessionRecord?
    var isStarting: Bool

    private var status: SessionVisualState {
        if isStarting { return .starting }
        return SessionVisualState(session: session)
    }

    private var metadata: String {
        if !detail.launcher.tags.isEmpty {
            return detail.launcher.tags.prefix(2).joined(separator: " · ")
        }
        let count = detail.launcher.actions.count
        return "\(detail.project.displayName) · \(count) service\(count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.color)
                .frame(width: 13)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(detail.launcher.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(metadata)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.label), \(detail.launcher.name), \(metadata)")
    }
}

private struct LauncherInspector: View {
    @ObservedObject var viewModel: LauncherViewModel
    var detail: LauncherDetail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: SessionRecord? {
        viewModel.activeSession(for: detail)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                inspectorHeader

                LaunchRail(
                    viewModel: viewModel,
                    detail: detail,
                    session: session,
                    reduceMotion: reduceMotion
                )

                Text(detail.launcher.description)
                    .font(.system(size: 15))
                    .foregroundStyle(RunwayPalette.carbonText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                launchConfiguration

                ManagedSessionActivity(
                    viewModel: viewModel,
                    detail: detail
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .tracklessOverlayScroller()
        .background(RunwayPalette.porcelain)
    }

    private var inspectorHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(detail.launcher.name)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(RunwayPalette.carbonText)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    SessionBadge(state: SessionVisualState(session: session))
                }

                Text(detail.project.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RunwayPalette.secondaryText)

                if !detail.launcher.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(detail.launcher.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(RunwayPalette.fog, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                    }
                    .accessibilityLabel("Tags: \(detail.launcher.tags.joined(separator: ", "))")
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                LifecycleButton(
                    viewModel: viewModel,
                    detail: detail,
                    reduceMotion: reduceMotion
                )

                if viewModel.primaryActiveSession(for: detail) != nil {
                    Button {
                        viewModel.requestRelaunch(detail: detail)
                    } label: {
                        Label("RELAUNCH", systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(0.35)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RunwayPalette.tide)
                    .disabled(!viewModel.canRelaunchSelected || viewModel.selectedLauncherID != detail.id)
                    .opacity(viewModel.canRelaunchSelected ? 1 : 0.5)
                    .help("Fully close the exact active session, then start a fresh one")
                    .accessibilityHint("Requires confirmation and allocates fresh managed ports where configured.")
                }

                Button {
                    viewModel.requestLaunchNew(for: detail)
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.startingAdditionalLauncherIDs.contains(detail.id) {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "plus.circle")
                        }
                        Text(viewModel.startingAdditionalLauncherIDs.contains(detail.id) ? "STARTING NEW…" : "LAUNCH NEW")
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(0.35)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(RunwayPalette.relay)
                .disabled(viewModel.startingAdditionalLauncherIDs.contains(detail.id) || viewModel.connectionError != nil)
                .opacity(viewModel.connectionError == nil ? 1 : 0.5)
                .help("Start an independent additional managed session with fresh managed ports where configured")
                .accessibilityHint("Creates an additional managed session without closing the primary session.")
            }
        }
    }

    private var launchConfiguration: some View {
        InspectorSection(title: "Launch configuration", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                ConfigurationRow(label: "Working directory") {
                    HStack(spacing: 8) {
                        Text(detail.project.directory)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Reveal") { viewModel.reveal(detail.project) }
                            .buttonStyle(.link)
                            .accessibilityLabel("Reveal \(detail.project.displayName) in Finder")
                    }
                }

                if let runDetails = detail.launcher.runDetails,
                   !runDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ConfigurationRow(label: "Run details") {
                        Text(runDetails)
                            .font(.system(size: 12))
                            .foregroundStyle(RunwayPalette.carbonText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                if detail.launcher.actions.first(where: { $0.id == detail.launcher.primaryActionID })?.allowsRuntimeArguments == true {
                    ConfigurationRow(label: "Arguments for next launch or relaunch") {
                        TextField(
                            "For example: --device iPhone --mode debug",
                            text: Binding(
                                get: { viewModel.argumentsText(for: detail.id) },
                                set: { viewModel.setArgumentsText($0, for: detail.id) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(
                            viewModel.startingLauncherIDs.contains(detail.id)
                                || viewModel.startingAdditionalLauncherIDs.contains(detail.id)
                        )
                        .accessibilityHint("Quotes and backslash escapes are supported. Leave untouched to preserve an exact session's stored arguments; editing supplies the next launch or relaunch override.")
                    }
                }
            }
        }
    }
}

private struct LifecycleButton: View {
    @ObservedObject var viewModel: LauncherViewModel
    var detail: LauncherDetail
    var reduceMotion: Bool

    @FocusState private var focused: Bool
    @State private var hovered = false

    private enum Mode: Equatable {
        case launch
        case starting
        case close
        case stopping
        case relaunching
    }

    private var activeSessions: [SessionRecord] {
        viewModel.activeSessions(for: detail)
    }

    private var activeSession: SessionRecord? {
        activeSessions.first
    }

    private var mode: Mode {
        // The start request itself can remain pending through a long readiness wait. As soon as
        // polling exposes its exact active session, CLOSE must win over the local in-flight flag
        // so the user can cancel that wait through the daemon's tested stop-during-start path.
        if let session = activeSession {
            if viewModel.isRelaunching(session) { return .relaunching }
            if session.state == .stopping || viewModel.stoppingSessionIDs.contains(session.id) {
                return .stopping
            }
            return .close
        }
        if viewModel.startingLauncherIDs.contains(detail.id) { return .starting }
        return .launch
    }

    private var title: String {
        switch mode {
        case .launch: return "LAUNCH"
        case .starting: return "STARTING…"
        case .close: return activeSessions.count > 1 ? "CLOSE ALL" : "CLOSE"
        case .stopping: return activeSessions.count > 1 ? "CLOSING ALL…" : "CLOSING…"
        case .relaunching: return "RELAUNCHING…"
        }
    }

    private var busy: Bool {
        mode == .starting || mode == .stopping || mode == .relaunching
    }

    var body: some View {
        Button {
            Task { await viewModel.requestLifecycleAction(for: detail) }
        } label: {
            HStack(spacing: 7) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(mode == .starting || mode == .relaunching ? .white : .primary)
                }
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.55)
            }
            .frame(minWidth: 98, minHeight: 34)
            .padding(.horizontal, 4)
            .foregroundStyle(mode == .launch || mode == .starting || mode == .relaunching ? Color.white : Color(nsColor: .systemRed))
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(focused ? RunwayPalette.tide : borderColor, lineWidth: focused ? 3 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .disabled(busy || viewModel.connectionError != nil)
        .opacity(viewModel.connectionError == nil ? 1 : 0.55)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            mode == .close
                ? (activeSessions.count > 1
                    ? "Shows one confirmation before stopping all exact active sessions."
                    : "Shows a confirmation before stopping the exact active session.")
                : "Starts this registered launcher using fresh managed ports when configured."
        )
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                mode == .relaunching
                    ? RunwayPalette.tide
                    : (mode == .launch || mode == .starting
                        ? RunwayPalette.ignition.opacity(hovered ? 0.88 : 1)
                        : RunwayPalette.porcelain.opacity(hovered ? 0.7 : 1))
            )
    }

    private var borderColor: Color {
        mode == .close || mode == .stopping ? Color(nsColor: .systemRed).opacity(0.75) : .clear
    }

    private var accessibilityLabel: String {
        switch mode {
        case .launch: return "Launch \(detail.launcher.name)"
        case .starting: return "Starting \(detail.launcher.name)"
        case .close:
            return activeSessions.count > 1
                ? "Close all active \(detail.launcher.name) sessions"
                : "Close active \(detail.launcher.name) session"
        case .stopping:
            return activeSessions.count > 1
                ? "Closing all active \(detail.launcher.name) sessions"
                : "Closing active \(detail.launcher.name) session"
        case .relaunching: return "Relaunching \(detail.launcher.name)"
        }
    }
}

private struct LaunchRail: View {
    @ObservedObject var viewModel: LauncherViewModel
    var detail: LauncherDetail
    var session: SessionRecord?
    var reduceMotion: Bool

    @State private var showsAllActions = false

    private var actions: [LaunchAction] {
        detail.launcher.sortedActions
    }

    private var visibleActions: [LaunchAction] {
        showsAllActions ? actions : Array(actions.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LAUNCH RAIL")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(1.15)
                        .foregroundStyle(RunwayPalette.railMuted)
                    Text(detail.project.directory)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(RunwayPalette.railText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    viewModel.reveal(detail.project)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RunwayPalette.railMuted)
                .help("Reveal working directory")
                .accessibilityLabel("Reveal working directory in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Rectangle()
                .fill(Color.white.opacity(0.11))
                .frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(visibleActions.enumerated()), id: \.element.id) { index, action in
                    ServiceLane(
                        viewModel: viewModel,
                        detail: detail,
                        action: action,
                        run: session?.actionRuns.first(where: { $0.actionID == action.id }),
                        session: session,
                        reduceMotion: reduceMotion
                    )
                    if index < visibleActions.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 16)
                    }
                }
            }

            if actions.count > 4 {
                Button(showsAllActions ? "Show fewer services" : "Show \(actions.count - 4) more services") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        showsAllActions.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RunwayPalette.railMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
        .background(RunwayPalette.carbon, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Launch rail for \(detail.launcher.name)")
    }
}

private struct ServiceLane: View {
    @ObservedObject var viewModel: LauncherViewModel
    var detail: LauncherDetail
    var action: LaunchAction
    var run: ActionRunRecord?
    var session: SessionRecord?
    var reduceMotion: Bool

    private var state: ActionVisualState {
        ActionVisualState(run: run, session: session)
    }

    private var target: LaneTarget {
        LaneTarget(action: action, run: run)
    }

    var body: some View {
        HStack(spacing: 10) {
            stateGlyph

            VStack(alignment: .leading, spacing: 3) {
                Text(action.name.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(RunwayPalette.railMuted)
                    .lineLimit(1)
                Text(action.displayCommand.isEmpty ? "No command" : action.displayCommand)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(RunwayPalette.railText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(state.color.opacity(0.75))
                .frame(width: 20, height: 1)
                .accessibilityHidden(true)

            targetView

            Button {
                viewModel.copyToPasteboard(action.displayCommand)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RunwayPalette.railMuted)
            .help("Copy command")
            .accessibilityLabel("Copy \(action.name) command")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: state)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stateGlyph: some View {
        if state == .starting {
            ProgressView()
                .controlSize(.small)
                .tint(state.color)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Starting")
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 16, height: 16)
                .accessibilityLabel(state.label)
        }
    }

    @ViewBuilder
    private var targetView: some View {
        if let endpoint = target.endpoint {
            Button {
                viewModel.openEndpoint(endpoint)
            } label: {
                Text(target.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(state.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.color)
            .help(endpoint)
            .accessibilityLabel("Open \(action.name) endpoint, \(endpoint)")
        } else {
            Text(target.label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.color)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(state.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityLabel("Target: \(target.label)")
        }
    }
}

private struct InspectorSection<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RunwayPalette.secondaryText)
            content
        }
        .padding(16)
        .background(RunwayPalette.fog.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(RunwayPalette.divider, lineWidth: 1)
        )
    }
}

private struct ConfigurationRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(RunwayPalette.secondaryText)
            content
        }
    }
}

private struct ManagedSessionActivity: View {
    @ObservedObject var viewModel: LauncherViewModel
    var detail: LauncherDetail

    private var sessions: [SessionRecord] {
        viewModel.activeSessions(for: detail)
    }

    var body: some View {
        InspectorSection(title: "Managed sessions", symbol: "rectangle.3.group") {
            HStack {
                Text("Each card controls one exact managed session.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
                Spacer()
                Button("History") {
                    viewModel.presentHistory(for: detail)
                }
                .buttonStyle(.link)
                .accessibilityHint("Shows managed launch history for this launcher.")
            }

            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("No active managed session", systemImage: "circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RunwayPalette.secondaryText)
                    if let last = detail.lastSession {
                        HStack {
                            Text(lastSessionSummary(last))
                                .font(.system(size: 11.5))
                                .foregroundStyle(RunwayPalette.secondaryText)
                            Spacer()
                            Button("Show last log") {
                                Task { await viewModel.showLog(for: last, launcherName: detail.launcher.name) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(sessions) { session in
                        ManagedSessionCard(viewModel: viewModel, detail: detail, session: session)
                    }
                }
            }
        }
    }

    private func lastSessionSummary(_ session: SessionRecord) -> String {
        let state = session.state.rawValue.capitalized
        if let endedAt = session.endedAt {
            return "\(state) \(endedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return state
    }
}

private struct ManagedSessionCard: View {
    @ObservedObject var viewModel: LauncherViewModel
    var detail: LauncherDetail
    var session: SessionRecord

    private var openOptionsFingerprint: String {
        session.actionRuns.map { run in
            [
                run.id.uuidString, run.state.rawValue, run.endpointURL ?? "",
                run.pid.map(String.init) ?? "", run.pidStartIdentity ?? "",
                run.simulatorUDID ?? "", run.simulatorName ?? "",
            ].joined(separator: "|")
        }.joined(separator: ";")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(session.launchRole == .primary ? "PRIMARY" : "ADDITIONAL")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(session.launchRole == .primary ? RunwayPalette.tide : RunwayPalette.relay)
                        SessionBadge(state: SessionVisualState(session: session))
                    }
                    Text("Session \(String(session.id.uuidString.prefix(8)))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(RunwayPalette.carbonText)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("Log") {
                    Task { await viewModel.showLog(for: session, launcherName: detail.launcher.name) }
                }
                .buttonStyle(.link)

                SessionOpenMenu(viewModel: viewModel, session: session)

                Button("Relaunch") {
                    viewModel.requestRelaunch(detail: detail, session: session)
                }
                .buttonStyle(.link)
                .disabled(!viewModel.canRelaunch(session))

                Button("Close", role: .destructive) {
                    viewModel.requestClose(session: session, launcherName: detail.launcher.name)
                }
                .buttonStyle(.link)
                .disabled(viewModel.stoppingSessionIDs.contains(session.id) || session.state == .stopping)
            }

            HStack(spacing: 16) {
                SessionDatum(label: "Started", value: session.startedAt.formatted(date: .omitted, time: .shortened))
                SessionDatum(label: "Services", value: "\(session.actionRuns.count)")
                if let pid = session.actionRuns.compactMap(\.pid).first {
                    SessionDatum(label: "PID", value: String(pid))
                }
            }

            SessionEndpoints(session: session)

            if let error = session.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .textSelection(.enabled)
            }
        }
        .padding(13)
        .background(RunwayPalette.porcelain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(session.launchRole == .primary ? RunwayPalette.tide.opacity(0.38) : RunwayPalette.relay.opacity(0.38), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.launchRole.rawValue) managed session \(String(session.id.uuidString.prefix(8)))")
        .task(id: openOptionsFingerprint) {
            await viewModel.loadSessionOpenOptions(for: session, force: true)
        }
    }
}

private struct SessionOpenMenu: View {
    @ObservedObject var viewModel: LauncherViewModel
    var session: SessionRecord

    private var options: [SessionOpenOption] {
        viewModel.sessionOpenOptions[session.id] ?? []
    }

    var body: some View {
        Menu {
            if viewModel.loadingSessionOpenOptionIDs.contains(session.id) {
                Label("Loading destinations…", systemImage: "arrow.triangle.2.circlepath")
            } else if let error = viewModel.sessionOpenOptionErrors[session.id] {
                Text(error)
                Button("Retry destinations") {
                    Task { await viewModel.loadSessionOpenOptions(for: session, force: true) }
                }
            } else if options.isEmpty {
                Text("No openable destination reported")
                Button("Refresh destinations") {
                    Task { await viewModel.loadSessionOpenOptions(for: session, force: true) }
                }
            } else {
                ForEach(options) { option in
                    Button {
                        Task { await viewModel.openSessionOption(option) }
                    } label: {
                        Label(option.menuLabel, systemImage: option.symbol)
                    }
                    .disabled(viewModel.openingSessionOptionIDs.contains(option.id))

                    if option.kind == .expoIOS || option.kind == .expoAndroid || option.kind == .expoWeb {
                        Button("Probe \(option.label)") {
                            Task { await viewModel.probeSessionOpenOption(option) }
                        }
                        .disabled(viewModel.probingSessionOptionIDs.contains(option.id))
                    }
                }
                Divider()
                Button("Refresh destinations") {
                    Task { await viewModel.loadSessionOpenOptions(for: session, force: true) }
                }
            }
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Use only daemon-derived browser, application, Simulator, or Expo destinations for this exact managed session.")
        .accessibilityLabel("Open managed session destination")
        .accessibilityHint("Shows server-derived destinations for this exact session.")
    }
}

private extension SessionOpenOption {
    var menuLabel: String {
        guard kind == .browser,
              let detail,
              let url = URL(string: detail) else { return label }
        let host = url.host ?? "browser"
        let destination = url.port.map { "\(host):\($0)" } ?? host
        return "Open \(destination)"
    }

    var symbol: String {
        switch kind {
        case .browser: return "safari"
        case .application: return "app.badge.checkmark"
        case .simulator: return "iphone"
        case .expoIOS: return "iphone"
        case .expoAndroid: return "rectangle.portrait.and.arrow.forward"
        case .expoWeb: return "globe"
        }
    }
}

private struct SessionEndpoints: View {
    var session: SessionRecord

    private var runsWithTargets: [ActionRunRecord] {
        session.actionRuns.filter { $0.port != nil || $0.endpointURL != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Managed ports and endpoints")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(RunwayPalette.secondaryText)
            if runsWithTargets.isEmpty {
                Text("No managed port or endpoint was reported for this session.")
                    .font(.system(size: 11))
                    .foregroundStyle(RunwayPalette.secondaryText)
            } else {
                ForEach(runsWithTargets) { run in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(run.actionName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 96, alignment: .leading)
                        if let port = run.port {
                            Text(":\(port)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RunwayPalette.tide)
                                .textSelection(.enabled)
                        }
                        if let endpoint = run.endpointURL {
                            Text(endpoint)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RunwayPalette.carbonText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

private struct SessionDatum: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(RunwayPalette.secondaryText)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(RunwayPalette.carbonText)
                .textSelection(.enabled)
        }
    }
}

private struct SessionBadge: View {
    var state: SessionVisualState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("Status: \(state.label)")
    }
}

private struct EmptyInspector: View {
    var isLoading: Bool

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                Text("Connecting to the launcher service…")
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(RunwayPalette.tide)
                Text("Select a launcher")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("Inspect its command rail, then launch the exact registered task.")
                    .font(.system(size: 13))
                    .foregroundStyle(RunwayPalette.secondaryText)
            }
        }
        .padding(36)
        .multilineTextAlignment(.center)
        .foregroundStyle(RunwayPalette.carbonText)
    }
}

private struct LauncherStatusBar: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isStartingService {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: viewModel.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(viewModel.isConnected ? RunwayPalette.relay : Color(nsColor: .systemOrange))
                    .accessibilityHidden(true)
            }

            if viewModel.isStartingService {
                Text("Starting background process…")
            } else if let service = viewModel.snapshot?.service {
                Text(viewModel.isConnected ? "Registry connected" : "Using last registry snapshot")
                Text("·")
                    .foregroundStyle(RunwayPalette.secondaryText)
                Text("\(viewModel.launchers.count) launcher\(viewModel.launchers.count == 1 ? "" : "s")")
                Text("· v\(service.version)")
                    .foregroundStyle(RunwayPalette.secondaryText)
            } else {
                Text("Launcher service unavailable")
            }

            if let error = viewModel.connectionError {
                Text("· \(error)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help(error)
            }

            Spacer()

            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing launcher registry")
            }

            if let updated = viewModel.lastUpdatedAt {
                Text(updated, style: .relative)
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .accessibilityLabel("Updated \(updated.formatted(date: .omitted, time: .standard))")
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh launchers")
            .accessibilityLabel("Refresh launcher registry")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(RunwayPalette.carbonText)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(RunwayPalette.fog)
        .accessibilityElement(children: .contain)
    }
}

private struct LauncherLogSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.LogPresentation

    @Environment(\.dismiss) private var dismiss

    private var presentation: LauncherViewModel.LogPresentation {
        viewModel.logPresentation?.id == initial.id ? viewModel.logPresentation! : initial
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch investigation")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Diagnosis and command evidence · \(presentation.launcherName)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RunwayPalette.secondaryText)
                }
                Spacer()
                if !presentation.text.isEmpty {
                    Button("Copy") { viewModel.copyToPasteboard(presentation.text) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Group {
                if presentation.isLoading {
                    ProgressView("Loading session log…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = presentation.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        Text("Couldn’t load this log")
                            .font(.headline)
                        Text(error)
                            .foregroundStyle(RunwayPalette.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if presentation.diagnoses.isEmpty {
                                InvestigationEmptySummary(hasOutput: !presentation.text.isEmpty)
                            } else {
                                ForEach(Array(presentation.diagnoses.enumerated()), id: \.offset) { _, diagnosis in
                                    LaunchFailureDiagnosisCard(diagnosis: diagnosis)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Label("Raw command output", systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(RunwayPalette.railText)
                                ScrollView([.horizontal, .vertical]) {
                                    Text(presentation.text.isEmpty ? "This session has no log output." : presentation.text)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(RunwayPalette.railText)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .padding(13)
                                }
                                .frame(minHeight: 180, maxHeight: 320)
                                .background(RunwayPalette.carbon.opacity(0.76), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .padding(16)
                    }
                    .background(RunwayPalette.carbon)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .background(RunwayPalette.porcelain)
    }
}

private struct InvestigationEmptySummary: View {
    var hasOutput: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasOutput ? "checkmark.circle" : "questionmark.circle")
                .foregroundStyle(hasOutput ? RunwayPalette.relay : RunwayPalette.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text(hasOutput ? "No failure was detected in this session." : "No diagnostic evidence was captured.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RunwayPalette.railText)
                Text(hasOutput ? "Raw command output is available below." : "The raw output below is all Launcher could retain for this session.")
                    .font(.system(size: 11))
                    .foregroundStyle(RunwayPalette.railMuted)
            }
        }
        .padding(13)
        .background(RunwayPalette.fog.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LaunchFailureDiagnosisCard: View {
    var diagnosis: LaunchFailureDiagnosis

    private var color: Color {
        switch diagnosis.origin {
        case .projectCommand: return Color(nsColor: .systemOrange)
        case .launcherLifecycle, .processObservation: return RunwayPalette.ignition
        case .unknown: return RunwayPalette.secondaryText
        }
    }

    private var symbol: String {
        switch diagnosis.origin {
        case .projectCommand: return "wrench.and.screwdriver.fill"
        case .launcherLifecycle: return "gearshape.2.fill"
        case .processObservation: return "waveform.path.ecg"
        case .unknown: return "questionmark.diamond.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnosis.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(RunwayPalette.railText)
                    Text(diagnosis.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(RunwayPalette.railMuted)
                }
                Spacer(minLength: 8)
                Text(diagnosis.confidence.rawValue.uppercased() + " CONFIDENCE")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.14), in: Capsule())
            }

            InvestigationFact(label: "Root cause", value: diagnosis.rootCause)
            InvestigationFact(label: "Lifecycle", value: diagnosis.lifecycle)
            InvestigationFact(label: "Suggested next step", value: diagnosis.nextStep, accent: RunwayPalette.tide)

            if !diagnosis.evidence.isEmpty {
                DisclosureGroup("Evidence (\(diagnosis.evidence.count))") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(diagnosis.evidence, id: \.self) { evidence in
                            Label(evidence, systemImage: "checkmark.circle")
                                .font(.system(size: 10.5))
                                .foregroundStyle(RunwayPalette.railMuted)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(RunwayPalette.railMuted)
            }
        }
        .padding(14)
        .background(RunwayPalette.fog.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.42), lineWidth: 1)
        }
    }
}

private struct InvestigationFact: View {
    var label: String
    var value: String
    var accent: Color = RunwayPalette.railText

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(RunwayPalette.railMuted)
            Text(value)
                .font(.system(size: 11.25))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LauncherHistorySheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.HistoryPresentation

    @Environment(\.dismiss) private var dismiss

    private var presentation: LauncherViewModel.HistoryPresentation {
        viewModel.historyPresentation?.id == initial.id ? viewModel.historyPresentation! : initial
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { presentation.selectedSessionID },
            set: { selectedID in
                guard var current = viewModel.historyPresentation, current.id == initial.id else { return }
                current.selectedSessionID = selectedID
                viewModel.historyPresentation = current
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Managed launch history")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(presentation.launcherID == nil ? "All managed launchers" : "This launcher")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RunwayPalette.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if presentation.isLoading {
                ProgressView("Loading managed launch history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = presentation.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text("Couldn’t load history")
                        .font(.headline)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(RunwayPalette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: selection) {
                        ForEach(presentation.sessions) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.launcherName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(session.launchRole.rawValue.uppercased()) · \(session.state.rawValue.uppercased())")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(session.launchRole == .primary ? RunwayPalette.tide : RunwayPalette.relay)
                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(RunwayPalette.secondaryText)
                            }
                            .padding(.vertical, 3)
                            .tag(session.id)
                        }
                        if presentation.nextCursor != nil {
                            Button {
                                Task { await viewModel.loadMoreHistory() }
                            } label: {
                                HStack {
                                    Spacer()
                                    if presentation.isLoadingMore {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Load more")
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(presentation.isLoadingMore)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 255)

                    Divider()

                    Group {
                        if let session = presentation.selectedSession {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 15) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(session.launcherName)
                                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                            HStack(spacing: 7) {
                                                Text(session.launchRole.rawValue.uppercased())
                                                    .font(.system(size: 9.5, weight: .bold))
                                                    .tracking(0.65)
                                                    .foregroundStyle(session.launchRole == .primary ? RunwayPalette.tide : RunwayPalette.relay)
                                                SessionBadge(state: SessionVisualState(session: session))
                                            }
                                        }
                                        Spacer()
                                        Button("Show log") {
                                            Task { await viewModel.showLog(for: session, launcherName: session.launcherName) }
                                        }
                                        .buttonStyle(.link)
                                    }
                                    HStack(spacing: 16) {
                                        SessionDatum(label: "Session", value: String(session.id.uuidString.prefix(8)))
                                        SessionDatum(label: "Started", value: session.startedAt.formatted(date: .omitted, time: .shortened))
                                        SessionDatum(label: "Services", value: "\(session.actionRuns.count)")
                                    }
                                    SessionEndpoints(session: session)
                                    if let diagnosis = sessionFailureDiagnosis(session) {
                                        HistoryFailureSummary(diagnosis: diagnosis)
                                    }
                                }
                                .padding(18)
                            }
                        } else {
                            Text("Select a managed session")
                                .foregroundStyle(RunwayPalette.secondaryText)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(RunwayPalette.porcelain)
        .sheet(item: $viewModel.logPresentation) { initial in
            LauncherLogSheet(viewModel: viewModel, initial: initial)
        }
    }
}

private func sessionFailureDiagnosis(_ session: SessionRecord) -> LaunchFailureDiagnosis? {
    guard session.state == .failed || session.state == .orphaned || session.lastError != nil else { return nil }
    let failedRun = session.actionRuns.last(where: { $0.state == .failed || $0.state == .orphaned })
    if let stored = failedRun?.failureDiagnosis { return stored }
    return LaunchFailureDiagnoser.diagnose(
        LaunchFailureDiagnosisInput(
            launcherMessage: failedRun?.message ?? session.lastError,
            processStarted: failedRun?.pid != nil
        )
    )
}

private struct HistoryFailureSummary: View {
    var diagnosis: LaunchFailureDiagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(diagnosis.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(diagnosis.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(RunwayPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Show log for root cause, lifecycle evidence, and raw command output.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(RunwayPalette.tide)
        }
        .padding(12)
        .background(Color(nsColor: .systemOrange).opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private enum SessionVisualState: Equatable {
    case idle
    case starting
    case running
    case partial
    case stopping
    case failed
    case orphaned

    init(session: SessionRecord?) {
        guard let session else {
            self = .idle
            return
        }
        switch session.state {
        case .starting: self = .starting
        case .running: self = .running
        case .partial: self = .partial
        case .stopping: self = .stopping
        case .exited: self = .idle
        case .failed: self = .failed
        case .orphaned: self = .orphaned
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting"
        case .running: return "Running"
        case .partial: return "Partial"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        case .orphaned: return "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .starting: return "clock"
        case .running: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .stopping: return "stop.circle"
        case .failed: return "xmark.octagon.fill"
        case .orphaned: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return RunwayPalette.secondaryText
        case .starting: return RunwayPalette.ignition
        case .running: return RunwayPalette.relay
        case .partial: return Color(nsColor: .systemOrange)
        case .stopping: return Color(nsColor: .systemOrange)
        case .failed: return Color(nsColor: .systemRed)
        case .orphaned: return Color(nsColor: .systemOrange)
        }
    }
}

private enum ActionVisualState: Equatable {
    case idle
    case queued
    case starting
    case running
    case stopping
    case exited
    case failed
    case orphaned

    init(run: ActionRunRecord?, session: SessionRecord?) {
        guard let run else {
            self = session?.isActive == true ? .queued : .idle
            return
        }
        switch run.state {
        case .starting: self = .starting
        case .running: self = .running
        case .stopping: self = .stopping
        case .exited: self = .exited
        case .failed: self = .failed
        case .orphaned: self = .orphaned
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .exited: return "Exited"
        case .failed: return "Failed"
        case .orphaned: return "Orphaned"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .queued: return "ellipsis.circle"
        case .starting: return "clock"
        case .running: return "checkmark.circle.fill"
        case .stopping: return "stop.circle"
        case .exited: return "circle"
        case .failed: return "xmark.octagon.fill"
        case .orphaned: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle, .queued, .exited: return RunwayPalette.railMuted
        case .starting: return RunwayPalette.ignition
        case .running: return RunwayPalette.relay
        case .stopping: return Color(nsColor: .systemOrange)
        case .failed: return Color(nsColor: .systemRed)
        case .orphaned: return Color(nsColor: .systemOrange)
        }
    }
}

private struct LaneTarget {
    var label: String
    var endpoint: String?

    init(action: LaunchAction, run: ActionRunRecord?) {
        if let endpoint = run?.endpointURL, !endpoint.isEmpty {
            self.endpoint = endpoint
            if let port = run?.port {
                label = ":\(port)"
            } else {
                label = "OPEN"
            }
            return
        }

        if let port = run?.port {
            label = ":\(port)"
            endpoint = nil
            return
        }

        endpoint = nil
        switch action.port.mode {
        case .automatic:
            label = "AUTO → —"
        case .fixed:
            label = action.port.fixedPort.map { ":\($0)" } ?? "PORT"
        case .none:
            switch action.openTarget {
            case .browser: label = "BROWSER"
            case .application: label = "APP"
            case .simulator: label = "DEVICE"
            case .none: label = action.runner == .url ? "URL" : "PROCESS"
            }
        }
    }
}

private struct ExternalProcessRow: View {
    var observation: ExternalProcessObservation
    var selected: Bool

    private var ports: String {
        observation.endpoints.map(\.displayValue).joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RunwayPalette.ignition)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("STARTED SEPARATELY")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.55)
                    .foregroundStyle(RunwayPalette.ignition)
                Text(observation.command.displayCommand)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RunwayPalette.carbonText)
                    .lineLimit(1)
                Text("PID \(observation.pid) · \(ports)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(RunwayPalette.tide)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(selected ? RunwayPalette.tide.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ExternalProcessInspector: View {
    @ObservedObject var viewModel: LauncherViewModel
    var observation: ExternalProcessObservation

    private var ports: String {
        observation.endpoints.map(\.displayValue).joined(separator: ", ")
    }

    private var ownershipMessage: String {
        switch observation.ownership.kind {
        case .launcherOwned:
            return "This listener is already Launcher-owned and remains in the managed session list."
        case .codexPort:
            return "This listener is managed by codex-port outside this Launcher session. Close is delegated only through its recorded owner."
        case .external:
            return "This listener was observed outside Launcher. It is not a managed session; selecting it does not adopt or alter any managed launch."
        case .ambiguous:
            return observation.ownership.message
        }
    }

    private func browserLabel(for endpoint: ExternalListenerEndpoint) -> String {
        let host = endpoint.family == .ipv6 ? "[\(endpoint.loopbackHost)]" : endpoint.loopbackHost
        return "Try http://\(host):\(endpoint.port)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("STARTED SEPARATELY", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.75)
                            .foregroundStyle(RunwayPalette.ignition)
                        Text(observation.command.displayCommand)
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                            .foregroundStyle(RunwayPalette.carbonText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text("This process does not have a corresponding managed Launcher session. You can create a reviewed launcher shortcut without taking over this running process.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(RunwayPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 8) {
                        if !observation.endpoints.isEmpty {
                            Menu {
                                ForEach(observation.endpoints) { endpoint in
                                    Button(browserLabel(for: endpoint)) {
                                        viewModel.openExternalEndpoint(endpoint)
                                    }
                                }
                            } label: {
                                Label("OPEN", systemImage: "arrow.up.forward.app")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .tracking(0.35)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Try an observed TCP port in the default browser. The protocol is not assumed or adopted.")
                        }

                        Button {
                            Task { await viewModel.requestExternalLauncherDraft(for: observation) }
                        } label: {
                            Label(viewModel.isLoadingExternalDraft ? "PREPARING…" : "ADD LAUNCHER", systemImage: "plus.rectangle.on.rectangle")
                                .font(.system(size: 10.5, weight: .bold))
                                .tracking(0.35)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RunwayPalette.tide)
                        .disabled(viewModel.isLoadingExternalDraft)
                        .help("Open an editable draft; no launcher is created until you review and save it.")
                        .accessibilityHint("Opens a reviewed draft and never saves automatically.")

                        Button(role: .destructive) {
                            Task { await viewModel.requestExternalClose(for: observation) }
                        } label: {
                            Label(viewModel.isPreparingExternalClose ? "PREPARING…" : "CLOSE", systemImage: "xmark.circle")
                                .font(.system(size: 10.5, weight: .bold))
                                .tracking(0.35)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RunwayPalette.ignition)
                        .disabled(!observation.canClose || viewModel.isPreparingExternalClose)
                        .help(observation.closeDisabledReason ?? "Prepare an exact typed confirmation before signalling this external process.")
                        .accessibilityHint("Shows the process warning and requires the exact server-issued confirmation phrase.")
                    }
                }

                InspectorSection(title: "Observed process", symbol: "waveform.path.ecg") {
                    VStack(alignment: .leading, spacing: 13) {
                        ConfigurationRow(label: "Command") {
                            Text(observation.command.displayCommand)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RunwayPalette.carbonText)
                                .textSelection(.enabled)
                        }
                        ConfigurationRow(label: "Working directory") {
                            Text(observation.workingDirectory ?? "Not reported")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RunwayPalette.carbonText)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 28) {
                            SessionDatum(label: "PID", value: String(observation.pid))
                            SessionDatum(label: "Started", value: observation.startedAt.formatted(date: .abbreviated, time: .shortened))
                            SessionDatum(label: "Origin", value: observation.command.provenance.rawValue)
                        }
                        ConfigurationRow(label: "Ports") {
                            Text(ports.isEmpty ? "No listener endpoint reported" : ports)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RunwayPalette.tide)
                                .textSelection(.enabled)
                        }
                    }
                }

                InspectorSection(title: "Ownership", symbol: "person.crop.circle.badge.questionmark") {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(observation.ownership.kind.rawValue, systemImage: "shield.lefthalf.filled")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(RunwayPalette.ignition)
                        Text(ownershipMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(RunwayPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let warning = viewModel.externalProcessSnapshot?.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .tracklessOverlayScroller()
        .background(RunwayPalette.porcelain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("External listener PID \(observation.pid)")
    }
}

private struct ExternalCloseSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.ExternalClosePresentation

    private var presentation: LauncherViewModel.ExternalClosePresentation {
        viewModel.externalClosePresentation ?? initial
    }

    private var confirmationBinding: Binding<String> {
        Binding(
            get: { presentation.confirmationText },
            set: { value in
                guard var current = viewModel.externalClosePresentation else { return }
                current.confirmationText = value
                viewModel.externalClosePresentation = current
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Close external listener", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(RunwayPalette.ignition)
            Text(presentation.intent.warning)
                .font(.system(size: 12.5))
                .foregroundStyle(RunwayPalette.carbonText)
                .fixedSize(horizontal: false, vertical: true)
            InspectorSection(title: "Exact process", symbol: "waveform.path.ecg") {
                VStack(alignment: .leading, spacing: 8) {
                    SessionDatum(label: "PID", value: String(presentation.intent.pid))
                    SessionDatum(label: "Started", value: presentation.intent.startedAt.formatted(date: .abbreviated, time: .shortened))
                    ConfigurationRow(label: "Command") {
                        Text(presentation.intent.command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    ConfigurationRow(label: "Ports") {
                        Text(presentation.intent.endpoints.map(\.displayValue).joined(separator: ", "))
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Text("Type this exact confirmation to signal only the observed process:")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(RunwayPalette.secondaryText)
            Text(presentation.intent.confirmationText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RunwayPalette.fog, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            TextField("Exact confirmation", text: confirmationBinding)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Exact external close confirmation")
            HStack {
                Button("Cancel") { viewModel.externalClosePresentation = nil }
                Spacer()
                Button("Close external process", role: .destructive) {
                    Task { await viewModel.confirmExternalClose(presentation) }
                }
                .disabled(presentation.confirmationText != presentation.intent.confirmationText)
            }
        }
        .padding(24)
        .frame(width: 570)
        .background(RunwayPalette.porcelain)
        .interactiveDismissDisabled(false)
    }
}

private struct LauncherEditorSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.LauncherEditPresentation
    @State private var selectedActionID: UUID?
    @State private var isAdvancedActionPropertiesExpanded = false

    private var presentation: LauncherViewModel.LauncherEditPresentation {
        viewModel.launcherEditPresentation ?? initial
    }

    private var draft: LauncherRecord { presentation.draft }

    private var selectedAction: LaunchAction? {
        let id = selectedActionID ?? draft.primaryActionID
        return draft.actions.first(where: { $0.id == id }) ?? draft.sortedActions.first
    }

    private var selectedActionBinding: Binding<UUID> {
        Binding(
            get: { selectedAction?.id ?? draft.primaryActionID },
            set: { selectedActionID = $0 }
        )
    }

    private func launcherBinding<Value>(_ keyPath: WritableKeyPath<LauncherRecord, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in viewModel.updateLauncherEditor { $0.draft[keyPath: keyPath] = value } }
        )
    }

    private func actionBinding<Value>(
        _ actionID: UUID,
        _ keyPath: WritableKeyPath<LaunchAction, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft.actions.first(where: { $0.id == actionID })?[keyPath: keyPath] ?? fallback },
            set: { value in viewModel.updateLauncherEditorAction(actionID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func actionStringBinding(
        _ actionID: UUID,
        _ keyPath: WritableKeyPath<LaunchAction, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft.actions.first(where: { $0.id == actionID })?[keyPath: keyPath] ?? "" },
            set: { value in
                viewModel.updateLauncherEditorAction(actionID) {
                    $0[keyPath: keyPath] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                }
            }
        )
    }

    private func portBinding<Value>(
        _ actionID: UUID,
        _ keyPath: WritableKeyPath<PortConfiguration, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft.actions.first(where: { $0.id == actionID })?.port[keyPath: keyPath] ?? fallback },
            set: { value in
                viewModel.updateLauncherEditorAction(actionID) { action in
                    action.port[keyPath: keyPath] = value
                }
            }
        )
    }

    private func portStringBinding(
        _ actionID: UUID,
        _ keyPath: WritableKeyPath<PortConfiguration, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft.actions.first(where: { $0.id == actionID })?.port[keyPath: keyPath] ?? "" },
            set: { value in
                viewModel.updateLauncherEditorAction(actionID) { action in
                    action.port[keyPath: keyPath] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                }
            }
        )
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { presentation.tagsText },
            set: { value in viewModel.updateLauncherEditor { $0.tagsText = value } }
        )
    }

    private var runDetailsBinding: Binding<String> {
        Binding(
            get: { draft.runDetails ?? "" },
            set: { value in viewModel.updateLauncherEditor { $0.draft.runDetails = value } }
        )
    }

    private func argumentsBinding(for action: LaunchAction) -> Binding<String> {
        Binding(
            get: { presentation.argumentsText[action.id] ?? action.arguments.map(ShellEscaping.quote).joined(separator: " ") },
            set: { value in viewModel.setLauncherEditorArguments(value, for: action.id) }
        )
    }

    private func fixedPortBinding(for action: LaunchAction) -> Binding<String> {
        Binding(
            get: { action.port.fixedPort.map(String.init) ?? "" },
            set: { value in
                viewModel.updateLauncherEditorAction(action.id) { updated in
                    updated.port.fixedPort = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        )
    }

    private var launcherDeletePresentation: Binding<LauncherViewModel.LauncherDeletePresentation?> {
        Binding(
            get: {
                guard viewModel.launcherDeletePresentation?.presenterID == initial.id else { return nil }
                return viewModel.launcherDeletePresentation
            },
            set: { value in
                if let value {
                    guard value.presenterID == initial.id else { return }
                    viewModel.launcherDeletePresentation = value
                } else if viewModel.launcherDeletePresentation?.presenterID == initial.id {
                    viewModel.launcherDeletePresentation = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Edit Launcher")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(RunwayPalette.carbonText)
                Text("Update this saved launcher and its actions. Running sessions keep their exact existing definition; changes apply to later launches and relaunches.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    InspectorSection(title: "Launcher details", symbol: "pencil.and.list.clipboard") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: launcherBinding(\.name))
                            TextField("Description", text: launcherBinding(\.description))
                            TextField("Run details", text: runDetailsBinding)
                            TextField("Tags (comma-separated)", text: tagsBinding)
                            ConfigurationRow(label: "Project directory") {
                                Text(presentation.original.project.directory)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(RunwayPalette.secondaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if let action = selectedAction {
                        InspectorSection(title: "Saved actions", symbol: "terminal") {
                            VStack(alignment: .leading, spacing: 11) {
                                Picker("Action", selection: selectedActionBinding) {
                                    ForEach(draft.sortedActions) { candidate in
                                        Text(candidate.name).tag(candidate.id)
                                    }
                                }
                                .pickerStyle(.segmented)

                                TextField("Action name", text: actionBinding(action.id, \.name, fallback: action.name))
                                TextField("Action description", text: actionBinding(action.id, \.description, fallback: action.description))
                                TextField("Working directory", text: actionBinding(action.id, \.workingDirectory, fallback: action.workingDirectory))
                                Picker("Runner", selection: actionBinding(action.id, \.runner, fallback: action.runner)) {
                                    ForEach(ActionRunner.allCases, id: \.self) { runner in
                                        Text(runner.rawValue.capitalized).tag(runner)
                                    }
                                }
                                .pickerStyle(.segmented)

                                if action.runner == .shell {
                                    TextField("Shell command", text: actionStringBinding(action.id, \.shellCommand))
                                } else {
                                    TextField("Executable or target", text: actionStringBinding(action.id, \.executable))
                                }
                                TextField("Arguments", text: argumentsBinding(for: action))
                                if let error = presentation.argumentsErrors[action.id] {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Color(nsColor: .systemOrange))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(action.displayCommand)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(RunwayPalette.secondaryText)
                                    .textSelection(.enabled)
                            }
                        }

                        InspectorSection(title: "Ports and opening", symbol: "point.3.connected.trianglepath.dotted") {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("Port mode", selection: portBinding(action.id, \.mode, fallback: action.port.mode)) {
                                    Text("No port").tag(PortMode.none)
                                    Text("Fresh managed port").tag(PortMode.automatic)
                                    Text("Fixed port").tag(PortMode.fixed)
                                }
                                .pickerStyle(.segmented)
                                if action.port.mode == .fixed {
                                    TextField("Fixed port", text: fixedPortBinding(for: action))
                                }
                                TextField("Port label", text: portBinding(action.id, \.logicalName, fallback: action.port.logicalName))
                                TextField("Port environment", text: portBinding(action.id, \.environmentVariable, fallback: action.port.environmentVariable))
                                TextField("Host environment", text: portBinding(action.id, \.hostEnvironmentVariable, fallback: action.port.hostEnvironmentVariable))
                                TextField("Endpoint URL template", text: portStringBinding(action.id, \.URLTemplate))
                                TextField("Health-check URL", text: actionStringBinding(action.id, \.healthCheckURL))
                                Picker("Open after launch", selection: actionBinding(action.id, \.openTarget, fallback: action.openTarget)) {
                                    ForEach(OpenTarget.allCases, id: \.self) { target in
                                        Text(target.rawValue.capitalized).tag(target)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                isAdvancedActionPropertiesExpanded.toggle()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isAdvancedActionPropertiesExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 12)
                                    Text("Advanced action properties")
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RunwayPalette.carbonText)
                            .accessibilityLabel("Advanced action properties")
                            .accessibilityValue(isAdvancedActionPropertiesExpanded ? "Expanded" : "Collapsed")
                            .accessibilityHint("Shows or hides additional action properties.")

                            if isAdvancedActionPropertiesExpanded {
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle("Required for this launcher", isOn: actionBinding(action.id, \.required, fallback: action.required))
                                    Toggle("Accept runtime arguments", isOn: actionBinding(action.id, \.allowsRuntimeArguments, fallback: action.allowsRuntimeArguments))
                                    TextField("Application bundle identifier", text: actionStringBinding(action.id, \.appBundleIdentifier))
                                    Text("Order, timeouts, and inherited/environment values remain preserved. Use the command and port fields above for normal launcher edits.")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(RunwayPalette.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 6)
                            }
                        }
                    }

                    InspectorSection(title: "Danger zone", symbol: "trash") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Delete this saved launcher shortcut")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(RunwayPalette.carbonText)
                            Text("This cannot be undone. The daemon will first verify that no managed sessions are active. Deleting the shortcut never deletes project files or separately started processes.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(RunwayPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task {
                                    await viewModel.requestLauncherDeletion(
                                        for: presentation.original,
                                        presenterID: initial.id
                                    )
                                }
                            } label: {
                                Label(
                                    viewModel.isPreparingLauncherDeletion ? "PREPARING…" : "DELETE LAUNCHER…",
                                    systemImage: "trash"
                                )
                                .font(.system(size: 11.5, weight: .bold))
                                .tracking(0.4)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(RunwayPalette.ignition)
                                .background(
                                    RunwayPalette.ignition.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(RunwayPalette.ignition.opacity(0.55), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(presentation.isSaving || viewModel.isPreparingLauncherDeletion || viewModel.isDeletingLauncher)
                            .accessibilityLabel("Delete launcher \(presentation.original.launcher.name)")
                            .accessibilityHint("Shows an exact typed confirmation before removing only this saved launcher shortcut.")
                        }
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Cancel") { viewModel.launcherEditPresentation = nil }
                Spacer()
                Button(presentation.isSaving ? "SAVING…" : "SAVE CHANGES") {
                    Task { await viewModel.saveLauncherEditor() }
                }
                .disabled(!presentation.canSave)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 740, height: 720)
        .background(RunwayPalette.porcelain)
        .interactiveDismissDisabled(presentation.isSaving)
        .alert(item: scopedAlertBinding(viewModel: viewModel, presenterID: initial.id)) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: launcherDeletePresentation) { initial in
            LauncherDeleteSheet(viewModel: viewModel, initial: initial)
        }
        .onAppear {
            if selectedActionID == nil { selectedActionID = draft.primaryActionID }
            viewModel.registerScopedAlertPresenter(initial.id)
        }
        .onDisappear {
            viewModel.unregisterScopedAlertPresenter(initial.id)
        }
    }
}

private struct LauncherDeleteSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.LauncherDeletePresentation

    private var livePresentation: LauncherViewModel.LauncherDeletePresentation? {
        guard let current = viewModel.launcherDeletePresentation,
              current.id == initial.id,
              current.presenterID == initial.presenterID,
              current.intent == initial.intent else { return nil }
        return current
    }

    private var presentation: LauncherViewModel.LauncherDeletePresentation {
        livePresentation ?? initial
    }

    private var confirmationBinding: Binding<String> {
        Binding(
            get: { presentation.confirmationText },
            set: { value in
                guard var current = livePresentation else { return }
                current.confirmationText = value
                viewModel.launcherDeletePresentation = current
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Delete Launcher", systemImage: "trash")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(RunwayPalette.ignition)
                Text("This removes the saved Launcher shortcut only. It does not delete the project, its files, separately started processes, or managed history. Any unsaved edits in the editor will be discarded.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 15) {
                InspectorSection(title: "Shortcut to remove", symbol: "bookmark.slash") {
                    VStack(alignment: .leading, spacing: 8) {
                        SessionDatum(label: "Name", value: presentation.intent.launcher.launcher.name)
                        SessionDatum(label: "Description", value: presentation.intent.launcher.launcher.description)
                        SessionDatum(label: "Project", value: presentation.intent.launcher.project.displayName)
                        ConfigurationRow(label: "Directory") {
                            Text(presentation.intent.launcher.project.directory)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(RunwayPalette.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Type this exact launcher name to confirm deletion:")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(presentation.intent.launcher.launcher.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RunwayPalette.fog, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    TextField("Exact launcher name", text: confirmationBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Exact launcher deletion confirmation")
                }
            }
            .padding(24)

            Divider()

            HStack {
                Button("Cancel") { viewModel.cancelLauncherDeletion(presentation) }
                Spacer()
                Button("Delete Launcher", role: .destructive) {
                    guard let current = livePresentation else { return }
                    Task { await viewModel.confirmLauncherDeletion(current) }
                }
                .disabled(
                    livePresentation == nil
                        || presentation.confirmationText != presentation.intent.launcher.launcher.name
                        || viewModel.isDeletingLauncher
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 590)
        .background(RunwayPalette.porcelain)
        .interactiveDismissDisabled(viewModel.isDeletingLauncher)
    }
}

private struct ExternalLauncherDraftSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.ExternalDraftPresentation

    private var presentation: LauncherViewModel.ExternalDraftPresentation {
        viewModel.externalDraftPresentation ?? initial
    }

    private var draft: ExternalLauncherDraft { presentation.draft }

    private func binding<Value>(_ keyPath: WritableKeyPath<ExternalLauncherDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in viewModel.updateExternalDraft { $0[keyPath: keyPath] = value } }
        )
    }

    private var fixedPortBinding: Binding<String> {
        Binding(get: { presentation.fixedPortText }, set: viewModel.setExternalDraftFixedPort)
    }

    private var argumentsBinding: Binding<String> {
        Binding(
            get: { presentation.argumentsText },
            set: viewModel.setExternalDraftArguments
        )
    }

    private var runnerBinding: Binding<ExternalDraftRunner> {
        Binding(get: { draft.runner }, set: viewModel.setExternalDraftRunner)
    }

    private var executableBinding: Binding<String> {
        Binding(get: { draft.executable ?? "" }, set: viewModel.setExternalDraftExecutable)
    }

    private var shellCommandBinding: Binding<String> {
        Binding(get: { draft.shellCommand ?? "" }, set: viewModel.setExternalDraftShellCommand)
    }

    private var commandReviewedBinding: Binding<Bool> {
        Binding(get: { draft.commandReviewComplete }, set: viewModel.setExternalDraftCommandReviewed)
    }

    private var openInBrowserBinding: Binding<Bool> {
        Binding(get: { presentation.openInBrowser }, set: viewModel.setExternalDraftOpenInBrowser)
    }

    private var portModeBinding: Binding<ExternalDraftPortMode> {
        Binding(get: { draft.portPolicy.mode }, set: viewModel.setExternalDraftPortMode)
    }

    private var portPolicyGuidance: String {
        let fixedPortGuidance = presentation.origin == .externalObservation
            ? "A fixed port will fail while the separately started process still owns it."
            : "A fixed port must be free when this launcher starts."
        return "Fresh managed ports require the reviewed command to consume PORT/HOST (or ${PORT}/${HOST}). \(fixedPortGuidance) The browser suggestion is preselected only for common web commands; confirm it because not every TCP listener is HTTP."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add Launcher")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(RunwayPalette.carbonText)
                Text("This is an editable proposal only. Nothing is saved until the reviewed draft is explicitly saved.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    InspectorSection(title: "Launcher details", symbol: "rectangle.badge.plus") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: binding(\.name))
                            TextField("Description", text: binding(\.description))
                            TextField("Project directory", text: binding(\.projectDirectory))
                            Picker("Runner", selection: runnerBinding) {
                                Text("Process").tag(ExternalDraftRunner.process)
                                Text("Shell").tag(ExternalDraftRunner.shell)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    InspectorSection(title: "Reviewed command", symbol: "terminal") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(draft.displayCommand)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RunwayPalette.secondaryText)
                                .textSelection(.enabled)
                            if draft.runner == .process {
                                TextField("Executable", text: executableBinding)
                                TextField("Arguments", text: argumentsBinding)
                                if let error = presentation.argumentsError {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Color(nsColor: .systemOrange))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                TextField("Shell command", text: shellCommandBinding)
                            }
                            Toggle("I reviewed this exact command before saving", isOn: commandReviewedBinding)
                        }
                    }

                    InspectorSection(title: "Port policy", symbol: "point.3.connected.trianglepath.dotted") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Port mode", selection: portModeBinding) {
                                Text("Review required").tag(ExternalDraftPortMode.reviewRequired)
                                Text("Fresh managed port").tag(ExternalDraftPortMode.automatic)
                                Text("Fixed port").tag(ExternalDraftPortMode.fixed)
                                Text("No port").tag(ExternalDraftPortMode.none)
                            }
                            if draft.portPolicy.mode == .fixed {
                                TextField("Fixed port", text: fixedPortBinding)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Toggle("Offer this port as an HTTP browser destination", isOn: openInBrowserBinding)
                                .disabled(draft.portPolicy.mode == .none)
                            Text(portPolicyGuidance)
                                .font(.system(size: 10.5))
                                .foregroundStyle(RunwayPalette.secondaryText)
                        }
                    }

                    InspectorSection(title: "Review blockers", symbol: "exclamationmark.shield") {
                        if draft.blockers.isEmpty {
                            Label("All required review checks are complete", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(RunwayPalette.relay)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(draft.blockers, id: \.rawValue) { blocker in
                                    Label(blocker.reviewMessage, systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color(nsColor: .systemOrange))
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Cancel") { viewModel.externalDraftPresentation = nil }
                Spacer()
                Button(viewModel.isSavingExternalDraft ? "SAVING…" : "SAVE REVIEWED LAUNCHER") {
                    Task { await viewModel.saveExternalLauncherDraft() }
                }
                .disabled(!presentation.canSave || viewModel.isSavingExternalDraft)
                .accessibilityHint("Initializes the project and creates the launcher through the daemon only after every review blocker is cleared.")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 690, height: 690)
        .background(RunwayPalette.porcelain)
        .interactiveDismissDisabled(viewModel.isSavingExternalDraft)
        .alert(item: scopedAlertBinding(viewModel: viewModel, presenterID: initial.id)) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            viewModel.registerScopedAlertPresenter(initial.id)
        }
        .onDisappear {
            viewModel.unregisterScopedAlertPresenter(initial.id)
        }
    }
}

private extension ExternalDraftBlocker {
    var reviewMessage: String {
        switch self {
        case .nameRequired: return "Enter a globally unique launcher name."
        case .descriptionRequired: return "Describe what this launcher starts."
        case .commandUnavailable: return "Enter a complete runnable command."
        case .redactedCommand: return "Replace every redacted value with a safe reusable command."
        case .sanitizedCommand: return "Re-enter the command because unsafe display content was removed."
        case .commandReviewRequired: return "Acknowledge the exact reviewed command."
        case .projectDirectoryRequired: return "Choose the canonical project directory."
        case .portPolicyReviewRequired: return "Choose and complete a valid port policy."
        case .managedPortConsumptionRequired:
            return "Fresh managed port requires ${PORT}/${CODEX_PORT} in the reviewed command (Expo is adapted automatically)."
        }
    }
}

private struct SkillUninstallSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    var initial: LauncherViewModel.SkillUninstallPresentation

    private var livePresentation: LauncherViewModel.SkillUninstallPresentation? {
        guard let current = viewModel.skillUninstallPresentation,
              current.id == initial.id,
              current.presenterID == initial.presenterID,
              current.intent == initial.intent else { return nil }
        return current
    }

    private var presentation: LauncherViewModel.SkillUninstallPresentation {
        livePresentation ?? initial
    }

    private var confirmationBinding: Binding<String> {
        Binding(
            get: { presentation.confirmationText },
            set: { value in
                guard var current = livePresentation else { return }
                current.confirmationText = value
                viewModel.skillUninstallPresentation = current
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Uninstall Launcher skill", systemImage: "trash.slash")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(RunwayPalette.ignition)
                Text("Desktop and CLI share this one receipt-proven installation. The daemon will remove only the listed Launcher-managed files and preserve the listed unmanaged files.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    InspectorSection(title: "Shared installation", symbol: "link") {
                        VStack(alignment: .leading, spacing: 7) {
                            SessionDatum(label: "Host", value: presentation.intent.host.displayName)
                            SessionDatum(
                                label: "Affected surfaces",
                                value: presentation.intent.affectedSurfaces
                                    .map(\.displayName)
                                    .joined(separator: " + ")
                            )
                            SessionDatum(label: "Installed version", value: presentation.intent.installedVersion ?? "Unknown")
                            ConfigurationRow(label: "Desktop / CLI shared path") {
                                Text(presentation.intent.sharedInstallationPath)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    SkillPathList(title: "Managed files to remove", paths: presentation.intent.removablePaths, accent: RunwayPalette.ignition)
                    SkillPathList(title: "Unmanaged files preserved", paths: presentation.intent.preservedPaths, accent: RunwayPalette.relay)
                    Text(presentation.intent.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(RunwayPalette.secondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Type this exact confirmation to remove only the receipt-proven managed files:")
                    .font(.system(size: 11.5, weight: .medium))
                Text(presentation.intent.confirmationText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RunwayPalette.fog, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                TextField("Exact confirmation", text: confirmationBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Exact skill uninstall confirmation")
                HStack {
                    Button("Cancel") { viewModel.cancelSkillUninstall(presentation) }
                    Spacer()
                    Button("Uninstall managed files", role: .destructive) {
                        guard let current = livePresentation else { return }
                        Task { await viewModel.confirmSkillUninstall(current) }
                    }
                    .disabled(
                        livePresentation == nil
                            || presentation.confirmationText != presentation.intent.confirmationText
                            || viewModel.isUninstallingSkill
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 620)
        .frame(minHeight: 520, idealHeight: 620, maxHeight: 680)
        .background(RunwayPalette.porcelain)
        .interactiveDismissDisabled(viewModel.isUninstallingSkill)
    }
}

private struct SkillPathList: View {
    var title: String
    var paths: [String]
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(accent)
            if paths.isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(RunwayPalette.secondaryText)
            } else {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(RunwayPalette.carbonText)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct LauncherSettingsView: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Agent integration")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(RunwayPalette.carbonText)
                Text("Install or refresh the Launcher workflow for your coding agents at any time.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            SkillInstallerPanel(viewModel: viewModel)
                .padding(24)
        }
        .frame(width: 650, height: 520)
        .background(RunwayPalette.porcelain)
        .task { await viewModel.refreshLauncherSkillStatus(silent: true) }
    }
}

private struct SkillInstallerSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Install the Launcher skill")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .foregroundStyle(RunwayPalette.carbonText)
                    Text("Choose an agent, or save the canonical SKILL.md wherever you need it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RunwayPalette.secondaryText)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(RunwayPalette.fog, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.isInstallingAnySkill
                        || viewModel.isDownloadingSkill
                        || viewModel.isPreparingSkillUninstall
                        || viewModel.isUninstallingSkill
                )
                .help("Close")
                .accessibilityLabel("Close skill installer")
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 17)

            Divider()

            SkillInstallerPanel(viewModel: viewModel)
                .padding(24)
        }
        .frame(width: 620, height: 530)
        .background(RunwayPalette.porcelain)
        .interactiveDismissDisabled(
            viewModel.isInstallingAnySkill
                || viewModel.isDownloadingSkill
                || viewModel.isPreparingSkillUninstall
                || viewModel.isUninstallingSkill
        )
        .task { await viewModel.refreshLauncherSkillStatus(silent: true) }
    }
}

private struct SkillInstallerPanel: View {
    @ObservedObject var viewModel: LauncherViewModel
    @State private var presenterID = UUID()

    private var uninstallPresentation: Binding<LauncherViewModel.SkillUninstallPresentation?> {
        Binding(
            get: {
                guard viewModel.skillUninstallPresentation?.presenterID == presenterID else {
                    return nil
                }
                return viewModel.skillUninstallPresentation
            },
            set: { value in
                if let value {
                    guard value.presenterID == presenterID else { return }
                    viewModel.skillUninstallPresentation = value
                } else if viewModel.skillUninstallPresentation?.presenterID == presenterID {
                    viewModel.skillUninstallPresentation = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ONE INSTALLATION PER PRODUCT")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.65)
                        .foregroundStyle(RunwayPalette.tide)
                    Text("Desktop and CLI share one installed skill path. Launcher verifies at least one supported signed local product surface; each tile shows the current availability.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RunwayPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 14) {
                HostSkillTile(viewModel: viewModel, presenterID: presenterID, host: .codex, symbol: "chevron.left.forwardslash.chevron.right", accent: RunwayPalette.tide)
                HostSkillTile(viewModel: viewModel, presenterID: presenterID, host: .claudeCode, symbol: "sparkles", accent: RunwayPalette.relay)
                SkillChoiceTile(
                    title: "Download\nSKILL.md",
                    kindLabel: "FILE",
                    kindSymbol: "doc.text",
                    subtitle: "Choose a location",
                    symbol: "arrow.down.doc.fill",
                    stateLabel: viewModel.isDownloadingSkill ? "PREPARING" : "SAVE AS…",
                    accent: RunwayPalette.ignition,
                    enabled: !viewModel.isDownloadingSkill
                        && !viewModel.isPreparingSkillUninstall
                        && !viewModel.isUninstallingSkill
                        && !viewModel.hasPendingSkillUninstall
                        && viewModel.connectionError == nil,
                    busy: viewModel.isDownloadingSkill,
                    help: "Open the native save panel for the canonical standalone SKILL.md"
                ) {
                    Task { await viewModel.downloadLauncherSkill(presenterID: presenterID) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            SkillVerificationSummary(viewModel: viewModel, presenterID: presenterID)
        }
        .sheet(item: uninstallPresentation) { initial in
            SkillUninstallSheet(viewModel: viewModel, initial: initial)
        }
        .alert(item: scopedAlertBinding(viewModel: viewModel, presenterID: presenterID)) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            viewModel.registerScopedAlertPresenter(presenterID)
        }
        .onDisappear {
            viewModel.unregisterScopedAlertPresenter(presenterID)
        }
    }
}

private struct SkillVerificationSummary: View {
    @ObservedObject var viewModel: LauncherViewModel
    var presenterID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                if let error = viewModel.launcherSkillStatusError {
                    Label("VERIFICATION UNAVAILABLE", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemRed))
                    Text(error)
                        .foregroundStyle(RunwayPalette.secondaryText)
                        .lineLimit(2)
                } else {
                    Label("EXACT INSTALLED FILES", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(RunwayPalette.relay)
                    Text("Current means every Launcher-managed file and version matched exactly; product discovery is checked separately.")
                        .foregroundStyle(RunwayPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("PRODUCT DISCOVERY", systemImage: "rectangle.3.group")
                    .foregroundStyle(RunwayPalette.tide)
                    Text("Each product tile reports Desktop and CLI availability. Codex normally detects changes automatically; Claude detects changes live unless its top-level skills directory was just created.")
                        .foregroundStyle(RunwayPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 10.5))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task {
                    await viewModel.refreshLauncherSkillStatus(presenterID: presenterID)
                }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isRefreshingSkillStatus {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(viewModel.isRefreshingSkillStatus ? "CHECKING" : "CHECK AGAIN")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.5)
                }
                .foregroundStyle(RunwayPalette.carbonText)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RunwayPalette.porcelain, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(RunwayPalette.divider, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.isRefreshingSkillStatus
                    || viewModel.isInstallingAnySkill
                    || viewModel.isPreparingSkillUninstall
                    || viewModel.isUninstallingSkill
                    || viewModel.hasPendingSkillUninstall
            )
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Run exact installed-file verification and refresh Desktop/CLI availability for every product")
            .accessibilityLabel(viewModel.isRefreshingSkillStatus ? "Checking skill installation again" : "Check skill installation again")
            .accessibilityHint("Repeats exact file verification and refreshes Desktop and CLI availability for every product.")
        }
        .padding(11)
        .background(RunwayPalette.fog.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(RunwayPalette.divider, lineWidth: 1)
        )
    }
}

private struct HostSkillTile: View {
    @ObservedObject var viewModel: LauncherViewModel
    var presenterID: UUID
    var host: LauncherSkillHost
    var symbol: String
    var accent: Color

    private var status: LauncherSkillHostStatus? {
        viewModel.skillStatus(for: host)
    }

    private var busy: Bool {
        viewModel.isInstallingSkill(for: host)
    }

    private var enabled: Bool {
        guard viewModel.launcherSkillStatusError == nil,
              let status,
              status.surfaces.contains(where: \.available) else { return false }
        return status.state != .blocked
            && !busy
            && !viewModel.isPreparingSkillUninstall
            && !viewModel.isUninstallingSkill
            && !viewModel.hasPendingSkillUninstall
    }

    private var canUninstall: Bool {
        guard let status else { return false }
        return status.canUninstall && status.managementState == .receiptProven
    }

    private var stateLabel: String {
        if busy { return "INSTALLING" }
        if viewModel.launcherSkillStatusError != nil { return "CHECK FAILED" }
        guard let status else { return "CHECKING" }
        if status.state == .blocked { return "BLOCKED" }
        if !status.surfaces.contains(where: \.available) {
            return status.state == .current ? "FILES CURRENT" : "NOT DETECTED"
        }
        switch status.state {
        case .unavailable: return "NOT DETECTED"
        case .notInstalled: return "INSTALL"
        case .outdated: return "UPDATE"
        case .current: return "REINSTALL"
        case .blocked: return "BLOCKED"
        }
    }

    private var subtitle: String {
        if busy { return "Writing shared files" }
        if viewModel.launcherSkillStatusError != nil { return "Status unavailable" }
        guard let status else { return "Checking availability" }
        let availability = status.surfaces.map { surface in
            "\(surface.surface.displayName) \(surface.available ? "detected" : "unavailable")"
        }
        return availability.isEmpty ? "No product surface reported" : availability.joined(separator: " · ")
    }

    private var help: String {
        if let error = viewModel.launcherSkillStatusError { return error }
        let discovery = status?.surfaces.map { surface in
            "\(surface.surface.displayName): \(surface.message)"
        }.joined(separator: " ") ?? "Checking Desktop and CLI availability."
        let files = status?.message ?? "Checking exact installed files."
        return "Product availability: \(discovery) Exact installed files: \(files)"
    }

    var body: some View {
        VStack(spacing: 7) {
            SkillChoiceTile(
                title: host.displayName,
                kindLabel: "PRODUCT",
                kindSymbol: "square.grid.2x2",
                subtitle: subtitle,
                symbol: symbol,
                stateLabel: stateLabel,
                accent: accent,
                enabled: enabled,
                busy: busy,
                help: help
            ) {
                Task {
                    await viewModel.installLauncherSkill(
                        for: host,
                        presenterID: presenterID
                    )
                }
            }

            if canUninstall {
                Button("UNINSTALL…", role: .destructive) {
                    Task {
                        await viewModel.requestSkillUninstall(
                            for: host,
                            presenterID: presenterID
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(RunwayPalette.ignition)
                .disabled(
                    viewModel.isInstallingAnySkill
                        || viewModel.isPreparingSkillUninstall
                        || viewModel.isUninstallingSkill
                        || viewModel.hasPendingSkillUninstall
                )
                .help("Review and confirm removal of only receipt-proven Launcher files. Desktop and CLI share the same installation path.")
                .accessibilityLabel("Uninstall receipt-proven Launcher skill for \(host.displayName)")
                .accessibilityHint("Shows the exact managed files that will be removed and the unmanaged files that will be preserved.")
            }
        }
    }
}

private struct SkillChoiceTile: View {
    var title: String
    var kindLabel: String
    var kindSymbol: String
    var subtitle: String
    var symbol: String
    var stateLabel: String
    var accent: Color
    var enabled: Bool
    var busy: Bool
    var help: String
    var action: () -> Void

    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accent)
                    }
                }

                Spacer()

                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(RunwayPalette.carbonText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Label(kindLabel, systemImage: kindSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.55)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .padding(.top, 3)

                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(RunwayPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Text(stateLabel)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.55)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.top, 9)
            }
            .padding(15)
            .frame(width: 168, height: 168, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovered && enabled ? RunwayPalette.fog.opacity(0.9) : RunwayPalette.fog.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focused ? accent : RunwayPalette.divider, lineWidth: focused ? 3 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .disabled(!enabled)
        .opacity(enabled || busy ? 1 : 0.58)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel("\(title.replacingOccurrences(of: "\n", with: " ")), \(kindLabel), \(subtitle), \(stateLabel.lowercased())")
        .accessibilityValue(busy ? "Busy" : (enabled ? "Available" : "Unavailable"))
        .accessibilityHint(help)
    }
}
