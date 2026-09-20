import AppKit
import SwiftUI

struct ServerRow: View {
    @EnvironmentObject private var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let server: DevServer
    @Binding var expandedID: String?
    var selected = false
    @State private var hovering = false

    private var expanded: Bool { expandedID == server.id }
    private var isStopping: Bool { store.stopping.contains(server.id) }
    private var health: Health { store.healthFor(server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                portColumn
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(server.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let framework = server.framework {
                            Text(framework.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    meta
                }
                Spacer(minLength: 4)
                actions
            }
            if let error = store.errors[server.id] {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.leading, 64)
                    .padding(.top, 4)
            }
            if expanded {
                ServerDetails(server: server)
                    .padding(.leading, 64)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.06 : hovering ? 0.045 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: selected ? 1.5 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expandedID = expanded ? nil : server.id }
        }
        .opacity(isStopping ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isStopping)
        .contextMenu { ServerMenu(server: server) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAction(.default) { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expandedID = expanded ? nil : server.id } }

    }

    private var accessibilityDescription: String {
        var parts = ["\(server.name)", server.framework?.name, "port \(server.primaryPort)", "started by \(server.owner.name)"]
        if server.isOrphaned { parts.append("orphaned") }
        if server.isExposed { parts.append("reachable from the network") }
        switch health {
        case .up(let ms): parts.append("responding in \(ms) milliseconds")
        case .down: parts.append("not responding")
        default: break
        }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    private var portColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: String(server.primaryPort))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
            if server.ports.count > 1 {
                Text(verbatim: "+\(server.ports.count - 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(server.ports.map { String($0.port) }.joined(separator: ", "))
            }
        }
        .frame(width: 52, alignment: .leading)
    }

    private var meta: some View {
        HStack(spacing: 9) {
            HealthDot(health: health, speaksHTTP: (store.url(server) != nil))
            HStack(spacing: 4) {
                OwnerMark(owner: server.owner)
                Text(server.owner.name).foregroundStyle(.primary.opacity(0.85))
            }
            .fixedSize()
            .help(server.owner.evidence)
            TimelineView(.periodic(from: .now, by: 20)) { context in
                Text(Format.age(since: server.startedAt, now: context.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("Started \(Format.started(server.startedAt))")
            if store.isProtected(server) { Image(systemName: "lock.shield").help("Protected from stop and restart") }
            if server.isOrphaned {
                Text("orphaned")
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)
                    .help("Nothing that started it is still running. It is probably safe to stop.")
            }
            if server.isExposed {
                Image(systemName: "network")
                    .foregroundStyle(.orange)
                    .help("Reachable by anyone on this network — the server is bound to all interfaces, not just localhost")
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if (store.url(server) != nil) {
                Button { store.open(server) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Open in browser")
                    .help("Open localhost:\(String(server.primaryPort))")
            }
            if store.canRestart(server) {
                Button { store.restart(server) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Restart")
                    .help(restartHelp)
            }
            if isStopping {
                ProgressView().controlSize(.small).frame(width: 26, height: 24)
            } else if store.canStop(server) {
                Button {
                    store.stop(server, force: NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(hoverTint: .red))
                .accessibilityLabel(server.brewService != nil ? "Stop service" : "Stop")
                .help(stopHelp)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }

    private var stopHelp: String {
        if let formula = server.brewService { return "Run brew services stop \(formula)" }
        if server.dockerContainer != nil { return "Stop the container (docker stop)" }
        return "Stop. Option-click to force quit."
    }

    private var restartHelp: String {
        if let formula = server.brewService { return "Run brew services restart \(formula)" }
        if server.dockerContainer != nil { return "Restart the container (docker restart)" }
        return "Stop and run its command again"
    }
}

/// A small dot that says whether the port actually answers, not just listens.
struct HealthDot: View {
    let health: Health
    var speaksHTTP = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(text)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch health {
        case .up(let ms): return ms < 800 ? .green : .yellow
        case .down: return .red
        case .checking, .unknown, .unavailable: return Color.secondary.opacity(0.45)
        }
    }

    private var text: String {
        switch health {
        case .up(let ms): return speaksHTTP ? "Responding in \(ms) ms" : "Accepting connections"
        case .down: return speaksHTTP ? "Listening, but not answering HTTP requests" : "Not accepting connections"
        case .checking: return "Checking…"
        case .unknown: return "Not checked yet"
        case .unavailable(let reason): return reason
        }
    }
}

struct ServerDetails: View {
    @EnvironmentObject private var store: Store
    @Environment(\.isSnapshot) private var isSnapshot
    let server: DevServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if let cwd = server.cwd {
                    row("Folder") {
                        Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                row("Command") {
                    Text(server.command)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let via = server.launchedVia {
                    row("Run with") { Text(via).font(.system(size: 10, design: .monospaced)) }
                }
                row("Started") {
                    Text("\(Format.started(server.startedAt)). \(server.owner.evidence)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                row("Stop ends") { chain }
                if server.memory > 0 || server.cpuPercent != nil {
                    row("Activity") {
                        Text(activity)
                    }
                }
                healthRow
                row("Ports") { endpoints }
                if !store.canRestart(server) && server.brewService == nil && server.dockerContainer == nil && store.canStop(server) {
                    row("Restart") { Text("Review a launch recipe to enable restart.").foregroundStyle(.secondary) }
                }
                if server.isExposed {
                    row("Exposed") {
                        Text("Bound outside loopback. Network access also depends on your firewall. Bind to a loopback address to keep it local.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let url = store.networkURL(server) {
                    row("Network") { Text(url.absoluteString).textSelection(.enabled) }
                }
                if let note = server.note {
                    row("Note") { Text(note).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .font(.system(size: 11))

            HStack(spacing: 6) {
                if server.cwd != nil {
                    Button("Finder") { store.reveal(server) }
                        .help("Reveal the folder in Finder")
                    if let editor = store.editorName {
                        Button(editor) { store.openInEditor(server) }
                            .help("Open the folder in \(editor)")
                    }
                    Button("Terminal") { store.openInTerminal(server) }
                        .help("Open a terminal in the folder")
                }
                if (store.url(server) != nil), let url = store.url(server) {
                    Button("Copy URL") { store.copy(url.absoluteString) }
                }
                Spacer()
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Spacer()
                if store.canRestart(server) {
                    Button("Restart") { store.restart(server) }
                        .help(restartHint)
                }
                if store.canStop(server) && server.canForceStop {
                    Button("Force quit") { store.stop(server, force: true) }
                        .help("Send SIGKILL right away")
                }
            }
            .controlSize(.small)
        }
    }

    private var restartHint: String {
        if server.dockerContainer != nil { return "docker restart \(server.name)" }
        if server.brewService != nil { return "brew services restart \(server.brewService!)" }
        return "Stop and run its command again"
    }

    private var activity: String {
        var parts: [String] = []
        if let cpu = server.cpuPercent { parts.append("\(cpu)% CPU") }
        if server.memory > 0 { parts.append(Format.memory(server.memory)) }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    @ViewBuilder private var healthRow: some View {
        let health = store.healthFor(server)
        switch health {
        case .up(let ms):
            row("Health") { Text((store.url(server) != nil) ? "Responding in \(ms) ms" : "Accepting connections") }
        case .down:
            row("Health") {
                Text((store.url(server) != nil) ? "Listening, but not answering requests. Check the protocol and log before restarting it." : "Not accepting connections.")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .checking:
            row("Health") { Text("Checking…").foregroundStyle(.secondary) }
        case .unknown:
            EmptyView()
        case .unavailable(let reason):
            row("Health") { Text(reason).foregroundStyle(.secondary) }
        }
    }

    private var endpoints: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(server.ports, id: \.self) { port in
                HStack(spacing: 6) {
                    HealthDot(health: store.healthFor(server, port: port), speaksHTTP: store.protocolFor(server, port) != .tcp)
                    Text(String(port.port)).monospacedDigit()
                    if isSnapshot {
                        Text(store.protocolFor(server, port).label).foregroundStyle(.secondary)
                    } else {
                    Menu(store.protocolFor(server, port).label) {
                        ForEach(ProbeProtocol.allCases, id: \.self) { mode in
                            Button(mode.label) { store.setProtocol(mode, server: server, port: port) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer(minLength: 0)
                    if let url = store.url(server, port: port) {
                        Button("Open") { store.open(server, port: port) }
                        Button("Copy") { store.copy(url.absoluteString) }
                    }
                    Button { store.pin(server, port: port.port) } label: { Image(systemName: "pin") }
                        .help("Pin this port")
                }.controlSize(.mini)
                Text(port.addresses.joined(separator: ", ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private var chain: some View {
        var text = Text("")
        for (i, link) in server.chain.enumerated() {
            if i > 0 { text = text + Text("  →  ").foregroundColor(.secondary) }
            text = text + Text(link.label) + Text(verbatim: " \(link.pid)").foregroundColor(.secondary)
        }
        if server.childCount > 0 {
            let noun = server.childCount == 1 ? "child process" : "child processes"
            text = text + Text(verbatim: ", plus \(server.childCount) \(noun)").foregroundColor(.secondary)
        }
        return text.fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ServerMenu: View {
    @EnvironmentObject private var store: Store
    let server: DevServer

    var body: some View {
        if (store.url(server) != nil), let url = store.url(server) {
            Button("Open \(url.host ?? "localhost"):\(String(server.primaryPort))") { store.open(server) }
            if let net = store.networkURL(server) {
                Button("Open on network (\(net.host ?? ""))") { store.openOnNetwork(server) }
                Button("Copy network URL") { store.copy(net.absoluteString) }
            }
            Button("Copy URL") { store.copy(url.absoluteString) }
        }
        if server.cwd != nil {
            Button("Reveal in Finder") { store.reveal(server) }
            if let editor = store.editorName {
                Button("Open in \(editor)") { store.openInEditor(server) }
            }
            Button("Open in Terminal") { store.openInTerminal(server) }
        }
        Button("Copy command") { store.copy(server.command) }
        if server.kind == .dev {
            Button(store.isProtected(server) ? "Unprotect service" : "Protect service") { store.toggleProtection(server) }
            if server.dockerContainer != nil || server.brewService != nil {
                Button("Save launch recipe") { store.saveManagedRecipe(server) }
            } else { Button("Review launch recipe…") { store.editRecipe(server) } }
        }
        Divider()
        if store.pinned?.serviceID == server.serviceID {
            Button("Unpin from menu bar") { store.unpin() }
        } else {
            Button("Pin in menu bar") { store.pin(server) }
        }
        Divider()
        if store.canRestart(server) {
            Button("Restart") { store.restart(server) }
        }
        if store.canStop(server) {
            Button(server.brewService != nil ? "Stop service" : server.dockerContainer != nil ? "Stop container" : "Stop") { store.stop(server) }
            if server.canForceStop { Button("Force quit") { store.stop(server, force: true) } }
        }
    }
}
