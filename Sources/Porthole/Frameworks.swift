import Foundation

/// Recognizes what a server is from its command line. The first entry with a
/// matching token wins, so specific tools come before the runtimes they use.
enum Frameworks {
    private struct Def {
        let name: String
        let color: UInt32
        var http = true
        let tokens: Set<String>
    }

    private static let defs: [Def] = [
        Def(name: "Next.js", color: 0x8E8E93, tokens: ["next", "next-server", "next-router-worker", "next-render-worker"]),
        Def(name: "Nuxt", color: 0x00C16A, tokens: ["nuxt", "nuxi", "@nuxt/cli"]),
        Def(name: "Astro", color: 0xFF5D01, tokens: ["astro"]),
        Def(name: "Remix", color: 0x3992FF, tokens: ["remix", "remix-serve", "@remix-run/dev"]),
        Def(name: "SvelteKit", color: 0xFF3E00, tokens: ["svelte-kit", "@sveltejs/kit"]),
        Def(name: "Storybook", color: 0xFF4785, tokens: ["storybook", "start-storybook", "@storybook/cli"]),
        Def(name: "Docusaurus", color: 0x3ECC5F, tokens: ["docusaurus", "@docusaurus/core"]),
        Def(name: "Gatsby", color: 0x663399, tokens: ["gatsby"]),
        Def(name: "Angular", color: 0xDD0031, tokens: ["ng", "@angular/cli"]),
        Def(name: "Expo", color: 0x4630EB, tokens: ["expo", "@expo/cli"]),
        Def(name: "Metro", color: 0xEF4242, tokens: ["metro", "react-native"]),
        Def(name: "HyperFrames", color: 0x7C5CFF, tokens: ["hyperframes"]),
        Def(name: "Remotion", color: 0x0B84F3, tokens: ["remotion", "@remotion/cli"]),
        Def(name: "Vitest", color: 0x729B1B, tokens: ["vitest"]),
        Def(name: "VitePress", color: 0x5C73E7, tokens: ["vitepress"]),
        Def(name: "Vite", color: 0x747BFF, tokens: ["vite"]),
        Def(name: "webpack", color: 0x5A9FD4, tokens: ["webpack", "webpack-dev-server", "webpack-cli"]),
        Def(name: "Create React App", color: 0x149ECA, tokens: ["react-scripts"]),
        Def(name: "Parcel", color: 0xE7A83C, tokens: ["parcel"]),
        Def(name: "Rsbuild", color: 0xF93920, tokens: ["rsbuild", "rspack", "@rspack/cli"]),
        Def(name: "Firebase emulators", color: 0xF5A300, tokens: ["firebase", "firebase-tools", "cloud-firestore-emulator", "cloud-storage-rules-runtime", "pubsub-emulator"]),
        Def(name: "Wrangler", color: 0xF38020, tokens: ["wrangler", "workerd"]),
        Def(name: "Vercel", color: 0x8E8E93, tokens: ["vercel"]),
        Def(name: "Netlify", color: 0x00AD9F, tokens: ["netlify", "netlify-cli"]),
        Def(name: "Eleventy", color: 0x8E8E93, tokens: ["eleventy", "@11ty/eleventy"]),
        Def(name: "Hugo", color: 0xFF4088, tokens: ["hugo"]),
        Def(name: "Jekyll", color: 0xCC0000, tokens: ["jekyll"]),
        Def(name: "Django", color: 0x2BA977, tokens: ["manage", "django", "django-admin"]),
        Def(name: "Flask", color: 0x3BABC3, tokens: ["flask"]),
        Def(name: "FastAPI", color: 0x009688, tokens: ["uvicorn", "fastapi", "hypercorn", "gunicorn", "granian"]),
        Def(name: "Streamlit", color: 0xFF4B4B, tokens: ["streamlit"]),
        Def(name: "Jupyter", color: 0xF37626, tokens: ["jupyter", "jupyter-lab", "jupyter-notebook", "jupyterlab"]),
        Def(name: "Gradio", color: 0xF97316, tokens: ["gradio"]),
        Def(name: "http.server", color: 0x3776AB, tokens: ["http.server", "simplehttpserver"]),
        Def(name: "Rails", color: 0xD30001, tokens: ["rails", "puma"]),
        Def(name: "Laravel", color: 0xFF2D20, tokens: ["artisan"]),
        Def(name: "Phoenix", color: 0xFD4F00, tokens: ["phx.server", "beam.smp"]),
        Def(name: "PHP", color: 0x777BB4, tokens: ["php"]),
        Def(name: ".NET", color: 0x512BD4, tokens: ["dotnet"]),
        Def(name: "Deno", color: 0x70D6A0, tokens: ["deno"]),
        Def(name: "Bun", color: 0xE8B98A, tokens: ["bun"]),
        Def(name: "PostgreSQL", color: 0x336791, http: false, tokens: ["postgres", "postmaster"]),
        Def(name: "MySQL", color: 0x4479A1, http: false, tokens: ["mysqld", "mariadbd"]),
        Def(name: "Redis", color: 0xDC382D, http: false, tokens: ["redis-server", "valkey-server"]),
        Def(name: "MongoDB", color: 0x47A248, http: false, tokens: ["mongod"]),
        Def(name: "Ollama", color: 0x8E8E93, tokens: ["ollama"]),
        Def(name: "ngrok", color: 0x5D6B98, tokens: ["ngrok"]),
        Def(name: "Static server", color: 0x8E8E93, tokens: ["http-server", "serve", "live-server", "browser-sync", "sirv"]),
        Def(name: "SSH tunnel", color: 0x8E8E93, http: false, tokens: ["ssh"]),
        Def(name: "Go", color: 0x00ADD8, tokens: ["air", "go-build"]),
        Def(name: "Java", color: 0xE76F00, tokens: ["java"]),
        Def(name: "Python", color: 0x3776AB, tokens: ["python", "python3"]),
        Def(name: "Node.js", color: 0x5FA04E, tokens: ["node", "nodemon", "tsx", "ts-node"]),
    ]

    static func detect(commands: [[String]], dependencies: Set<String>) -> Framework? {
        var tokens = Set<String>()
        for args in commands { tokens.formUnion(self.tokens(for: args)) }
        guard let def = defs.first(where: { !$0.tokens.isDisjoint(with: tokens) }) else { return nil }

        // Vite powers several frameworks; the project's dependencies tell them apart.
        if def.name == "Vite" {
            let refinements: [(String, String, UInt32)] = [
                ("@sveltejs/kit", "SvelteKit", 0xFF3E00),
                ("@react-router/dev", "React Router", 0xF44250),
                ("@remix-run/dev", "Remix", 0x3992FF),
                ("@tanstack/react-start", "TanStack Start", 0x0D9488),
                ("@analogjs/platform", "Analog", 0xC30F2E),
            ]
            if let hit = refinements.first(where: { dependencies.contains($0.0) }) {
                return Framework(name: hit.1, color: hit.2, speaksHTTP: true)
            }
        }
        return Framework(name: def.name, color: def.color, speaksHTTP: def.http)
    }

    /// Words that identify a tool: executable and script basenames, package
    /// names inside node_modules paths, and `python -m` modules.
    static func tokens(for args: [String]) -> Set<String> {
        var out = Set<String>()
        var previous = ""
        for arg in args {
            for word in arg.split(separator: " ") {
                let w = String(word)
                if w.hasPrefix("-") { previous = w; continue }
                out.insert(basename(w))
                if previous == "-m" { out.insert(w.lowercased()) }
                if w.hasSuffix(".jar") || w.contains("/") {
                    for pkg in packageNames(in: w) { out.insert(pkg) }
                }
                if w.contains("go-build") { out.insert("go-build") }
                previous = w
            }
        }
        return out
    }

    static func basename(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent.lowercased()
        for ext in [".js", ".mjs", ".cjs", ".ts", ".mts", ".py", ".jar", ".exe"] where name.hasSuffix(ext) {
            name.removeLast(ext.count)
            break
        }
        // "python3.13" -> "python3"
        if name.hasPrefix("python3.") { name = "python3" }
        return name
    }

    private static func packageNames(in path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        var names: [String] = []
        for (i, part) in parts.enumerated() where part == "node_modules" && i + 1 < parts.count {
            let next = parts[i + 1]
            if next == ".bin", i + 2 < parts.count {
                names.append(parts[i + 2].lowercased())
            } else if next.hasPrefix("@"), i + 2 < parts.count {
                names.append("\(next)/\(parts[i + 2])".lowercased())
            } else if !next.hasPrefix(".") {
                names.append(next.lowercased())
            }
        }
        // Firebase emulator jars: cloud-firestore-emulator-v1.19.7.jar
        if let jar = parts.last, jar.hasSuffix(".jar") {
            let base = jar.lowercased().replacingOccurrences(of: #"-v?[0-9][0-9.]*\.jar$"#, with: "", options: .regularExpression)
            names.append(base)
        }
        return names
    }
}
