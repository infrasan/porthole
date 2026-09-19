import Foundation

/// How to recognize whoever started a server: an AI agent, an editor, a terminal.
///
/// Porthole first walks up the live process tree. When the parent is gone
/// (the server is orphaned), it falls back to environment variables that the
/// agent left on the server process, which survive after the agent exits.
/// To teach Porthole about a new agent, add one entry here.
struct OwnerDef {
    let id: String
    let name: String
    let kind: Owner.Kind
    let color: UInt32
    /// Executable names, matched against the binary and the script it runs
    /// (`node /path/to/gemini` counts as `gemini`).
    var executables: [String] = []
    /// Substrings of the executable path or script path.
    var paths: [String] = []
    /// Prefixes of `__CFBundleIdentifier`, which macOS sets for anything
    /// launched from an app and which children inherit.
    var bundleIDs: [String] = []
    /// Values of `TERM_PROGRAM`.
    var termPrograms: [String] = []
    /// Environment variables an agent sets on the commands it runs.
    var envKeys: [String] = []
}

enum Catalog {
    static let owners: [OwnerDef] = [
        // AI agents. Checked before editors and terminals because an agent
        // usually runs inside one of those.
        OwnerDef(id: "claude-code", name: "Claude Code", kind: .agent, color: 0xD97757,
                 executables: ["claude"], paths: ["/claude-code/", "@anthropic-ai/claude-code"],
                 envKeys: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"]),
        OwnerDef(id: "codex", name: "Codex", kind: .agent, color: 0x10A37F,
                 executables: ["codex"], paths: ["@openai/codex"],
                 envKeys: ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_CI", "CODEX_MANAGED_BY_NPM"]),
        OwnerDef(id: "gemini", name: "Gemini CLI", kind: .agent, color: 0x4C8DF6,
                 executables: ["gemini"], paths: ["@google/gemini-cli"], envKeys: ["GEMINI_CLI"]),
        OwnerDef(id: "kimi", name: "Kimi", kind: .agent, color: 0x7B61FF,
                 executables: ["kimi", "kimi-cli"], paths: ["/.kimi-code/", "kimi-cli", "kimi_cli"], envKeys: ["KIMI_SESSION_ID"]),
        OwnerDef(id: "opencode", name: "OpenCode", kind: .agent, color: 0x5B6B7F,
                 executables: ["opencode"], paths: ["/.opencode/", "opencode-ai"], envKeys: ["OPENCODE_CLIENT", "OPENCODE"]),
        OwnerDef(id: "grok", name: "Grok", kind: .agent, color: 0x8A8A93,
                 executables: ["grok"], paths: ["/.grok/"], envKeys: ["GROK_SESSION_ID"]),
        OwnerDef(id: "cursor-agent", name: "Cursor Agent", kind: .agent, color: 0x6E6E73,
                 executables: ["cursor-agent"], envKeys: ["CURSOR_AGENT"]),
        OwnerDef(id: "copilot", name: "Copilot CLI", kind: .agent, color: 0x8957E5,
                 executables: ["copilot"], paths: ["@github/copilot"]),
        OwnerDef(id: "qwen", name: "Qwen Code", kind: .agent, color: 0x615CED,
                 executables: ["qwen"], paths: ["@qwen-code"]),
        OwnerDef(id: "amp", name: "Amp", kind: .agent, color: 0xF34E3F,
                 executables: ["amp"], paths: ["@sourcegraph/amp"]),
        OwnerDef(id: "aider", name: "Aider", kind: .agent, color: 0x14A34A, executables: ["aider"]),
        OwnerDef(id: "goose", name: "Goose", kind: .agent, color: 0x52525B, executables: ["goose"]),
        OwnerDef(id: "droid", name: "Droid", kind: .agent, color: 0xEA7317, executables: ["droid"]),
        OwnerDef(id: "crush", name: "Crush", kind: .agent, color: 0xD6338A, executables: ["crush"]),
        OwnerDef(id: "auggie", name: "Auggie", kind: .agent, color: 0x16A34A,
                 executables: ["auggie"], envKeys: ["AUGMENT_AGENT"]),

        // Desktop apps that run agents or dev servers.
        OwnerDef(id: "claude-app", name: "Claude", kind: .agent, color: 0xD97757,
                 paths: ["/Claude.app/"], bundleIDs: ["com.anthropic.claudefordesktop"]),
        OwnerDef(id: "chatgpt", name: "ChatGPT", kind: .agent, color: 0x10A37F,
                 paths: ["/ChatGPT.app/"], bundleIDs: ["com.openai.chat"]),
        OwnerDef(id: "cursor", name: "Cursor", kind: .app, color: 0x6E6E73,
                 paths: ["/Cursor.app/"], bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        OwnerDef(id: "windsurf", name: "Windsurf", kind: .app, color: 0x0B9A8D,
                 paths: ["/Windsurf.app/"], bundleIDs: ["com.exafunction.windsurf"]),
        OwnerDef(id: "vscode", name: "VS Code", kind: .app, color: 0x0A7ACC,
                 paths: ["/Visual Studio Code.app/", "/Visual Studio Code - Insiders.app/"],
                 bundleIDs: ["com.microsoft.VSCode"], termPrograms: ["vscode"]),
        OwnerDef(id: "zed", name: "Zed", kind: .app, color: 0x084CCF,
                 paths: ["/Zed.app/", "/Zed Preview.app/"], bundleIDs: ["dev.zed.Zed"], termPrograms: ["zed"]),
        OwnerDef(id: "kiro", name: "Kiro", kind: .app, color: 0x7C3AED, paths: ["/Kiro.app/"], bundleIDs: ["dev.kiro"]),
        OwnerDef(id: "antigravity", name: "Antigravity", kind: .app, color: 0x4285F4,
                 paths: ["/Antigravity.app/"], bundleIDs: ["com.google.antigravity"]),
        OwnerDef(id: "trae", name: "Trae", kind: .app, color: 0x22A06B, paths: ["/Trae.app/"]),
        OwnerDef(id: "xcode", name: "Xcode", kind: .app, color: 0x147EFB,
                 paths: ["/Xcode.app/Contents/MacOS/"], bundleIDs: ["com.apple.dt.Xcode"]),
        OwnerDef(id: "jetbrains", name: "JetBrains", kind: .app, color: 0xE0245E,
                 paths: ["/JetBrains/", "/IntelliJ IDEA", "/WebStorm", "/PyCharm", "/GoLand", "/Android Studio"],
                 bundleIDs: ["com.jetbrains.", "com.google.android.studio"]),

        // Terminals: a person typed the command.
        OwnerDef(id: "terminal", name: "Terminal", kind: .terminal, color: 0x8E8E93,
                 paths: ["/Terminal.app/"], bundleIDs: ["com.apple.Terminal"], termPrograms: ["Apple_Terminal"]),
        OwnerDef(id: "iterm", name: "iTerm2", kind: .terminal, color: 0x8E8E93,
                 executables: ["iTermServer"], paths: ["/iTerm.app/", "/iTerm2/iTermServer"],
                 bundleIDs: ["com.googlecode.iterm2"], termPrograms: ["iTerm.app"]),
        OwnerDef(id: "ghostty", name: "Ghostty", kind: .terminal, color: 0x8E8E93,
                 paths: ["/Ghostty.app/"], bundleIDs: ["com.mitchellh.ghostty"], termPrograms: ["ghostty"]),
        OwnerDef(id: "warp", name: "Warp", kind: .terminal, color: 0x8E8E93,
                 paths: ["/Warp.app/"], bundleIDs: ["dev.warp.Warp"], termPrograms: ["WarpTerminal"]),
        OwnerDef(id: "wezterm", name: "WezTerm", kind: .terminal, color: 0x8E8E93,
                 paths: ["/WezTerm.app/"], bundleIDs: ["com.github.wez.wezterm"], termPrograms: ["WezTerm"]),
        OwnerDef(id: "alacritty", name: "Alacritty", kind: .terminal, color: 0x8E8E93,
                 paths: ["/Alacritty.app/"], bundleIDs: ["org.alacritty", "io.alacritty"], termPrograms: ["alacritty"]),
        OwnerDef(id: "kitty", name: "kitty", kind: .terminal, color: 0x8E8E93,
                 paths: ["/kitty.app/"], bundleIDs: ["net.kovidgoyal.kitty"], termPrograms: ["kitty"]),
        OwnerDef(id: "hyper", name: "Hyper", kind: .terminal, color: 0x8E8E93,
                 paths: ["/Hyper.app/"], bundleIDs: ["co.zeit.hyper"], termPrograms: ["Hyper"]),
        OwnerDef(id: "tmux", name: "tmux", kind: .terminal, color: 0x8E8E93,
                 executables: ["tmux"], termPrograms: ["tmux"]),
        OwnerDef(id: "screen", name: "screen", kind: .terminal, color: 0x8E8E93, executables: ["screen"]),
    ]

    /// Environment variables Porthole reads. Everything else in a process's
    /// environment (API keys included) is discarded while parsing.
    static let envKeysOfInterest: Set<String> = {
        var keys: Set<String> = [
            "AI_AGENT", "TERM_PROGRAM", "__CFBundleIdentifier", "XPC_SERVICE_NAME",
            "npm_lifecycle_event", "npm_package_name", "npm_config_user_agent",
        ]
        for def in owners { keys.formUnion(def.envKeys) }
        return keys
    }()

    static func owner(forEnvBundleID id: String) -> OwnerDef? {
        owners.first { def in def.bundleIDs.contains { id.hasPrefix($0) } }
    }

    static func owner(forTermProgram value: String) -> OwnerDef? {
        owners.first { $0.termPrograms.contains(value) }
    }
}
