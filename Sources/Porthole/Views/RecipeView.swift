import SwiftUI

struct RecipeView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let draft: RecipeDraft
    @State private var executable: String
    @State private var directory: String
    @State private var arguments: String
    @State private var ports: String
    @State private var error: String?

    init(draft: RecipeDraft) {
        self.draft = draft
        _executable = State(initialValue: draft.recent.launchSpec?.executable ?? "")
        _directory = State(initialValue: draft.recent.launchSpec?.directory ?? draft.recent.cwd ?? "")
        _ports = State(initialValue: draft.recent.ports.map(String.init).joined(separator: ", "))
        _arguments = State(initialValue: draft.recent.launchSpec?.arguments.joined(separator: "\n") ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch \(draft.recent.name)").font(.system(size: 13, weight: .semibold))
            Text("Review the executable, arguments and working folder. Your original shell environment is not copied.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Executable path").font(.system(size: 11, weight: .medium))
                TextField("/absolute/path/to/executable", text: $executable).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Working folder").font(.system(size: 11, weight: .medium))
                TextField("/absolute/path/to/project", text: $directory).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments, one per line").font(.system(size: 11, weight: .medium))
                TextEditor(text: $arguments).font(.system(size: 11, design: .monospaced)).frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("Spaces stay inside each argument. Do not add shell quotes.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Expected ports").font(.system(size: 11, weight: .medium))
                TextField("3000, 8000", text: $ports).textFieldStyle(.roundedBorder)
                Text("Match the ports in your command. Startup waits for all of them.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save recipe") {
                    let spec = LaunchSpec(executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
                                          arguments: arguments.isEmpty ? [] : arguments.components(separatedBy: "\n"),
                                          directory: directory.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let reason = spec.validationError { error = reason; return }
                    guard FileManager.default.isExecutableFile(atPath: spec.executable) else { error = "Choose an executable file that exists on this Mac."; return }
                    let values = ports.split { $0 == "," || $0.isWhitespace }
                    let expected = values.compactMap { Int($0) }
                    guard !expected.isEmpty, expected.count == values.count, expected.allSatisfy({ (1...65535).contains($0) }) else {
                        error = "Enter ports between 1 and 65535, separated by commas."; return
                    }
                    var recent = draft.recent; recent.ports = Array(Set(expected)).sorted()
                    store.saveRecipe(recent, spec: spec); dismiss()
                }.keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }.padding(20).frame(width: 360)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Activity & diagnostics").font(.system(size: 13, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Stored on this Mac. Export includes project names, folders and redacted commands. No process environments are included.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.events.isEmpty { Text("Activity appears as servers start, stop or become orphaned.").font(.system(size: 11)).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.events) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.date, style: .time).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                            Text(event.name).lineLimit(1)
                            Spacer()
                            Text("\(event.port) · \(event.kind)").foregroundStyle(.secondary)
                        }.font(.system(size: 11))
                    }
                }
            }.frame(height: 220)
            Button("Export diagnostics…") { store.exportDiagnostics() }.controlSize(.small)
        }.padding(20).frame(width: 400)
    }
}
