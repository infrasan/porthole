import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showCount") private var showCount = true
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = true
    @AppStorage("recentsExpanded") private var recentsExpanded = true
    @State var expandedID: String?
    @State var showOthers = false
    @State private var showSearch = false
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSearch { searchField }
            if store.owners.count > 1 { filters }
            Divider().opacity(0.6)
            if let error = store.scanError ?? store.actionError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.actionError = nil; store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle()).help("Try again")
                }.padding(12)
                Divider()
            }
            if isSnapshot { inventory }
            else {
                ScrollViewReader { proxy in
                    ScrollView { inventory }
                        .frame(maxHeight: max(140, store.panelMaxHeight - 180))
                        .onChange(of: selectedID) { _, id in
                            if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) } }
                        }
                        .onChange(of: expandedID) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                }
            }
            if !store.servers.isEmpty { footer }
        }
        .frame(width: PanelStyle.width)
        .frame(maxHeight: isSnapshot ? nil : store.panelMaxHeight)
        .background {
            if !isSnapshot { WindowKeyObserver { store.isPanelOpen = $0 } }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) { expandSelected(true) }
        .onKeyPress(.leftArrow) { expandSelected(false) }
        .onKeyPress(.return) { toggleExpanded() }
        .onKeyPress(.space) { toggleExpanded() }
        .onKeyPress(.escape) { dismiss() }
        .background(shortcuts)
        .sheet(item: $store.recipeDraft) { RecipeView(draft: $0).environmentObject(store) }
        .sheet(isPresented: $store.diagnosticsPresented) { DiagnosticsView().environmentObject(store) }
        .onAppear { listFocused = true }
        .onChange(of: store.isPanelOpen) { _, open in if open { listFocused = true } }
    }

    private var inventory: some View {
        VStack(spacing: 0) {
            if store.servers.isEmpty { empty } else { list }
            if !store.visibleRecents.isEmpty { recents }
            if !store.others.isEmpty { others }
        }
    }

    // MARK: - Keyboard

    /// Rows in display order, the flat list the arrow keys walk through.
    private var orderedServers: [DevServer] { store.groups.flatMap(\.servers) }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !searchFocused else { return .ignored }
        let rows = orderedServers
        guard !rows.isEmpty else { return .ignored }
        guard let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = delta > 0 ? rows.first?.id : rows.last?.id
            return .handled
        }
        let next = min(max(index + delta, 0), rows.count - 1)
        self.selectedID = rows[next].id
        return .handled
    }

    private func expandSelected(_ expand: Bool) -> KeyPress.Result {
        guard !searchFocused else { return .ignored }
        guard let selectedID else { return .ignored }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expandedID = expand ? selectedID : nil }
        return .handled
    }

    private func toggleExpanded() -> KeyPress.Result {
        guard !searchFocused else { return .ignored }
        guard let selectedID else { return .ignored }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expandedID = expandedID == selectedID ? nil : selectedID }
        return .handled
    }

    private func dismiss() -> KeyPress.Result {
        if !store.query.isEmpty { store.query = ""; return .handled }
        if showSearch { showSearch = false; listFocused = true; return .handled }
        if expandedID != nil { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expandedID = nil }; return .handled }
        return .ignored
    }

    /// Hidden buttons carrying the ⌘ shortcuts so they work anywhere in the panel.
    private var shortcuts: some View {
        Group {
            Button("") { showSearch.toggle(); if showSearch { searchFocused = true } else { store.query = "" } }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { openSelected() }.keyboardShortcut("o", modifiers: .command)
            Button("") { copySelectedURL() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { stopSelected() }.keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func openSelected() {
        guard let server = orderedServers.first(where: { $0.id == selectedID }), store.url(server) != nil else { return }
        store.open(server)
    }

    private func copySelectedURL() {
        guard let server = orderedServers.first(where: { $0.id == selectedID }), let url = store.url(server) else { return }
        store.copy(url.absoluteString)
    }

    private func stopSelected() {
        guard let server = orderedServers.first(where: { $0.id == selectedID }), store.canStop(server) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop \(server.name)?"
        alert.informativeText = "This ends the process on port \(server.primaryPort), the way Ctrl-C in its terminal would."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.stop(server) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !store.orphans.isEmpty {
                Text("\(store.orphans.count) orphaned")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { showSearch.toggle(); if showSearch { searchFocused = true } else { store.query = "" } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .help("Search (⌘F)")
                .accessibilityLabel("Search")
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut("r")
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                settings
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var title: String {
        switch store.servers.count {
        case 0: return "No dev servers"
        case 1: return "1 dev server"
        default: return "\(store.servers.count) dev servers"
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Name, port, framework, owner…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var settings: some View {
        if isSnapshot {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 26, height: 24)
        } else {
            Menu {
                Text(versionTitle).font(.system(size: 11))
                Button("Check for Updates…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/infrasan/porthole/releases/latest")!)
                }
                Divider()
                Toggle("Show count in menu bar", isOn: $showCount)
                Toggle("Open at login", isOn: Binding(get: { store.launchesAtLogin }, set: { store.launchesAtLogin = $0 }))
                Toggle("Global hotkey \(HotKeyManager.display)", isOn: Binding(
                    get: { HotKeyManager.shared.isEnabled },
                    set: { HotKeyManager.shared.isEnabled = $0; store.actionError = HotKeyManager.shared.error }
                ))
                if let pinned = store.pinnedPort {
                    Button("Unpin port \(pinned) from menu bar") { store.unpin() }
                }
                Divider()
                Toggle("Notify when a server appears", isOn: notifyBinding(\.notifyNew))
                Toggle("Notify when a server stops", isOn: notifyBinding(\.notifyGone))
                Toggle("Notify about orphans", isOn: notifyBinding(\.notifyOrphan))
                Divider()
                Button("Activity & diagnostics…") { store.diagnosticsPresented = true }
                Divider()
                Button("Quit Porthole") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 24)
            .help("Settings")
        }
    }

    private var versionTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "Porthole \(version)" + (build.map { " (\($0))" } ?? "")
    }

    private func notifyBinding(_ keyPath: ReferenceWritableKeyPath<Store, Bool>) -> Binding<Bool> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { value in
                store[keyPath: keyPath] = value
                if value { store.requestNotificationPermission() }
            }
        )
    }

    // MARK: - Filters

    private var filters: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            FilterChip(title: "All", count: store.servers.count, owner: nil, selected: store.ownerFilter == nil) {
                store.ownerFilter = nil
            }
            ForEach(store.owners, id: \.owner.id) { entry in
                FilterChip(title: entry.owner.name, count: entry.count, owner: entry.owner,
                           selected: store.ownerFilter == entry.owner.id) {
                    store.ownerFilter = store.ownerFilter == entry.owner.id ? nil : entry.owner.id
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(store.groups) { group in
                if group.isMulti { groupHeader(group) }
                ForEach(group.servers) { server in
                    ServerRow(server: server, expandedID: $expandedID, selected: selectedID == server.id)
                }
            }
        }
        .padding(6)
    }

    private func groupHeader(_ group: ServerGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: "\(group.servers.count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer(minLength: 4)
            if !isSnapshot {
                Menu {
                    Button("Pin project") { store.pinProject(group) }
                    Button("Save project recipes") {
                        for server in group.servers where store.canRestart(server) { store.saveManagedRecipe(server) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                let eligible = store.stoppable(group.servers)
                if !eligible.isEmpty {
                    ConfirmButton(title: "Stop project", confirmTitle: "Stop \(eligible.count)?") { store.stop(eligible) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var list: some View {
        if isSnapshot {
            rows
        } else if store.visibleServers.isEmpty {
            Text("Nothing matches “\(store.query)”.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            // maxHeight, not a measured frame: the scroll view collapses to its
            // content when short and the hosting controller reports the total
            // as preferredContentSize, which the panel follows.
            rows
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(nsImage: MenuBarIcon.image(filled: false))
                .resizable()
                .frame(width: 30, height: 30)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(store.scanning && store.scannedAt == nil ? "Looking for servers…" : store.scanError != nil ? "Scan unavailable" : "Nothing is listening")
                .font(.system(size: 13, weight: .semibold))
            Text("Dev servers you or an agent start will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Recently stopped

    private var recents: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { recentsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(recentsExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(store.recents.contains(where: \.isSaved) ? "Saved & recently stopped" : "Recently stopped")
                    Text(verbatim: String(store.recents.count)).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if recentsExpanded {
                VStack(spacing: 1) {
                    ForEach(store.visibleRecents) { recent in
                        if let groupID = recent.groupID,
                           store.visibleRecents.first(where: { $0.groupID == groupID })?.id == recent.id,
                           store.visibleRecents.filter({ $0.groupID == groupID && $0.canStart }).count > 1 {
                            HStack {
                                Text(recent.groupName ?? "Project").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Start project") { store.startProject(groupID) }.controlSize(.small)
                            }.padding(.horizontal, 10).padding(.top, 8)
                        }
                        RecentRow(recent: recent)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Other listeners

    private var others: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { showOthers.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showOthers ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Apps and system")
                    Text(verbatim: String(store.others.count)).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showOthers {
                VStack(spacing: 1) {
                    ForEach(store.others) { OtherRow(server: $0) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let visible = store.stoppable(store.visibleServers)
        return VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if !store.stoppable(store.orphans).isEmpty {
                    let n = store.stoppable(store.orphans).count
                    ConfirmButton(title: "Stop \(n) orphaned", confirmTitle: "Stop \(n) orphaned \(n == 1 ? "server" : "servers")?", tint: .orange) {
                        store.stop(store.stoppable(store.orphans))
                    }
                }
                Spacer()
                if store.servers.contains(where: { store.isProtected($0) }) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Protected services are excluded")
                }
                if visible.count > 1 {
                    ConfirmButton(title: "Stop \(visible.count)",
                                  confirmTitle: "Stop \(visible.count) servers?") {
                        store.stop(visible)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}

/// A stopped server that can be brought back with one click.
struct RecentRow: View {
    @EnvironmentObject private var store: Store
    let recent: RecentServer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: String(recent.primaryPort))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if recent.isSaved { Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                        Text(recent.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let framework = recent.frameworkName {
                            Text(framework).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(store.launchStatus[recent.id] ?? (recent.isSaved ? "Saved launch recipe" : "stopped \(Format.age(since: recent.stoppedAt, now: context.date)) ago"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if store.starting.contains(recent.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { recent.canStart ? store.start(recent) : store.editRecipe(recent) } label: { Image(systemName: recent.canStart ? "play.fill" : "pencil") }
                        .buttonStyle(IconButtonStyle(hoverTint: .green))
                        .accessibilityLabel(recent.canStart ? "Start \(recent.name)" : "Review launch recipe")
                        .help(recent.canStart ? "Start server" : "Review launch recipe")
                    Button { store.removeRecent(recent.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Forget \(recent.name)")
                        .help("Remove from the list")
                        .disabled(store.hasLaunch(recent))
                }
            }
            if let error = store.recentErrors[recent.id] {
                HStack(spacing: 6) {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let log = store.recentLogs[recent.id] {
                        Button("Open log") { NSWorkspace.shared.open(log) }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 62)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Start") { store.start(recent) }.disabled(!recent.canStart || store.starting.contains(recent.id))
            if recent.dockerContainer == nil && recent.brewService == nil {
                Button("Edit launch recipe…") { store.editRecipe(recent) }
            }
            if store.hasLaunch(recent) { Button("Stop launch") { store.stopLaunch(recent) } }
            if let log = store.recentLogs[recent.id] {
                Button("Open log") { NSWorkspace.shared.open(log) }
            }
            Divider()
            Button("Remove") { store.removeRecent(recent.id) }.disabled(store.starting.contains(recent.id) || store.hasLaunch(recent))
        }
        .accessibilityElement(children: .combine)
    }
}

struct OtherRow: View {
    @EnvironmentObject private var store: Store
    let server: DevServer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: String(server.primaryPort))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if server.ports.count > 1 {
                    Text(verbatim: "+\(server.ports.count - 1)").font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
            .help(server.ports.map { String($0.port) }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let note = server.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if store.stopping.contains(server.id) {
                ProgressView().controlSize(.small)
            } else if store.canStop(server) && server.kind != .system {
                ConfirmButton(title: server.kind == .app ? "Quit" : "Stop", confirmTitle: server.kind == .app ? "Quit?" : "Stop?") {
                    store.stop(server)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contextMenu { ServerMenu(server: server) }
    }
}

/// Reports whether the menu bar panel is showing. The panel keeps its view
/// alive between openings, so onAppear alone is not reliable.
struct WindowKeyObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onChange?(true) })
            tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onChange?(false) })
            DispatchQueue.main.async { [weak self, weak window] in self?.onChange?(window?.isKeyWindow ?? false) }
        }
    }
}
