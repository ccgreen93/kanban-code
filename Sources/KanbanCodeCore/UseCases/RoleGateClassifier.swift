import Foundation

/// Finds the gated commands (`GateAction`) in a Bash command line.
///
/// It reads the line the way a shell splits it: segments at unquoted `;`,
/// `&&`, `||`, `|`, `&` and newlines, heredoc bodies skipped, wrappers such
/// as `sudo`, `env`, `kv env <file> --` and `npx` peeled off. It looks inside
/// `bash -c '...'`, `eval` and the remote command of `ssh`.
///
/// It is a guardrail for an agent bending its instructions, not a security
/// boundary: a command hidden in a script file it wrote is not seen.
public enum RoleGateClassifier {
    public static let defaultProtectedBranches = ["main", "master", "trunk", "production", "prod", "release/*", "release-*"]

    /// Remotes that deploy when pushed to.
    static let deployRemotes: Set<String> = ["heroku", "dokku", "production", "prod", "live", "deploy"]

    /// - Parameters:
    ///   - branch: the checkout's current branch, for a push with no refspec.
    ///   - protectedBranches: branch names, `*` matching the rest of a name.
    ///   - deployPatterns: extra regular expressions; a segment matching one
    ///     is a deploy.
    public static func classify(
        _ command: String,
        branch: String? = nil,
        protectedBranches: [String] = defaultProtectedBranches,
        deployPatterns: [String] = []
    ) -> [GateMatch] {
        let patterns = deployPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var matches: [GateMatch] = []
        classify(command, remote: false, branch: branch, protectedBranches: protectedBranches,
                 patterns: patterns, depth: 0, into: &matches)
        var seen = Set<String>()
        return matches.filter { seen.insert("\($0.action.rawValue)|\($0.detail)").inserted }
    }

    private static func classify(
        _ command: String, remote: Bool, branch: String?, protectedBranches: [String],
        patterns: [NSRegularExpression], depth: Int, into matches: inout [GateMatch]
    ) {
        guard depth < 4 else { return }
        for raw in segments(command) {
            let tokens = peel(raw)
            guard let first = tokens.first else { continue }
            let detail = raw.joined(separator: " ")
            let text = tokens.joined(separator: " ")
            let program = (first as NSString).lastPathComponent
            func add(_ action: GateAction) { matches.append(GateMatch(action: action, detail: detail)) }
            func recurse(_ inner: String, remote innerRemote: Bool) {
                classify(inner, remote: innerRemote, branch: innerRemote ? nil : branch,
                         protectedBranches: protectedBranches, patterns: patterns, depth: depth + 1, into: &matches)
            }

            if patterns.contains(where: { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }) {
                add(.deploy)
            }
            if program == "kanban" { continue }

            switch program {
            case "bash", "sh", "zsh", "dash":
                if let i = tokens.firstIndex(of: "-c"), i + 1 < tokens.count { recurse(tokens[i + 1], remote: remote) }
            case "eval":
                recurse(tokens.dropFirst().joined(separator: " "), remote: remote)
            case "ssh":
                if let inner = sshRemoteCommand(tokens) { recurse(inner, remote: true) }
            case "scp", "rsync":
                // Copying onto a server; copying from one is reading.
                if let dest = tokens.dropFirst().last(where: { !$0.hasPrefix("-") }), isRemotePath(dest) { add(.deploy) }
            case "git":
                for action in gitActions(tokens, branch: branch, protectedBranches: protectedBranches) { add(action) }
            case "gh":
                if let action = ghAction(tokens) { add(action) }
            case "curl", "wget", "http", "https", "xh":
                if let action = githubAPIAction(text, writes: true) { add(action) }
            default:
                if isDeploy(program: program, tokens: tokens, remote: remote) { add(.deploy) }
            }
        }
    }

    // MARK: - git

    static func gitActions(_ tokens: [String], branch: String?, protectedBranches: [String]) -> [GateAction] {
        var i = 1
        while i < tokens.count, tokens[i].hasPrefix("-") {
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"].contains(tokens[i]) { i += 1 }
            i += 1
        }
        guard i < tokens.count, tokens[i] == "push" else { return [] }
        let args = Array(tokens[(i + 1)...])
        var actions: [GateAction] = []
        var positionals: [String] = []
        var j = 0
        var tags = false
        while j < args.count {
            let arg = args[j]
            if arg == "--" { positionals += args[(j + 1)...]; break }
            if arg.hasPrefix("--") {
                let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
                switch name {
                case "--force", "--force-with-lease", "--force-if-includes", "--mirror", "--delete", "--prune":
                    actions.append(.forcePush)
                case "--all", "--branches":
                    actions.append(.protectedPush)
                case "--tags", "--follow-tags":
                    tags = true
                case "--push-option", "--receive-pack", "--exec", "--repo", "--signed":
                    if !arg.contains("=") && name != "--signed" { j += 1 }
                default: break
                }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                let flags = arg.dropFirst()
                if flags.contains("f") || flags.contains("d") { actions.append(.forcePush) }
                if flags.contains("o") { j += 1 }
            } else {
                positionals.append(arg)
            }
            j += 1
        }
        let remoteName = positionals.first
        let refspecs = Array(positionals.dropFirst())
        if let remoteName, deployRemotes.contains(remoteName) { actions.append(.deploy) }
        if tags { actions.append(.deploy) }
        var destinations: [String] = []
        for spec in refspecs {
            var spec = spec
            if spec.hasPrefix("+") { actions.append(.forcePush); spec.removeFirst() }
            if spec.hasPrefix(":") { actions.append(.forcePush); continue }
            let dest = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? spec
            if dest.hasPrefix("refs/tags/") || isVersionTag(dest) { actions.append(.deploy); continue }
            destinations.append(dest.hasPrefix("refs/heads/") ? String(dest.dropFirst("refs/heads/".count)) : dest)
        }
        if destinations.isEmpty, !tags, let branch { destinations = [branch] }
        let resolved = destinations.map { $0 == "HEAD" ? (branch ?? $0) : $0 }
        if resolved.contains(where: { isProtected($0, protectedBranches) }) {
            actions.append(.protectedPush)
        } else if !actions.contains(.protectedPush), !resolved.isEmpty || actions.isEmpty {
            actions.append(.push)
        }
        return actions
    }

    static func isProtected(_ branch: String, _ protected: [String]) -> Bool {
        protected.contains { pattern in
            if pattern.hasSuffix("*") { return branch.hasPrefix(String(pattern.dropLast())) }
            return branch == pattern
        }
    }

    static func isVersionTag(_ ref: String) -> Bool {
        ref.range(of: #"^v?\d+\.\d+(\.\d+)?([.-].*)?$"#, options: .regularExpression) != nil
    }

    // MARK: - gh

    static func ghAction(_ tokens: [String]) -> GateAction? {
        let args = tokens.dropFirst().filter { !$0.hasPrefix("-") }
        let sub = args.first ?? ""
        let verb = args.dropFirst().first ?? ""
        switch (sub, verb) {
        case ("pr", "merge"):
            return .merge
        case ("pr", "review"):
            return tokens.contains("--approve") || tokens.contains("-a") ? .approve : .pr
        case ("pr", "create"), ("pr", "comment"), ("pr", "edit"), ("pr", "ready"), ("pr", "close"), ("pr", "reopen"):
            return .pr
        case ("release", "create"), ("release", "upload"), ("release", "edit"), ("release", "delete"):
            return .deploy
        case ("workflow", "run"), ("workflow", "enable"):
            return .deploy
        case ("api", _):
            let text = tokens.joined(separator: " ")
            let writes = tokens.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) }
                || text.range(of: #"(-X|--method)[ =]?(POST|PUT|PATCH|DELETE)"#, options: [.regularExpression, .caseInsensitive]) != nil
            return githubAPIAction(text, writes: writes)
        default:
            return nil
        }
    }

    /// A call to the GitHub REST or GraphQL API that merges, approves or
    /// dispatches. `writes` is whether the call sends a body or a write method.
    static func githubAPIAction(_ text: String, writes: Bool) -> GateAction? {
        if text.range(of: #"mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest"#, options: .regularExpression) != nil {
            return .merge
        }
        let github = text.contains("api.github.com") || text.contains("repos/") || text.contains("graphql")
        guard github else { return nil }
        if text.range(of: #"pulls/\d+/merge"#, options: .regularExpression) != nil { return .merge }
        guard writes else { return nil }
        if text.contains("/reviews"), text.contains("APPROVE") { return .approve }
        if text.contains("/dispatches") || text.contains("/releases") || text.contains("/deployments") { return .deploy }
        return nil
    }

    // MARK: - deploy tools

    /// Subcommands that deploy, by program; an empty set means any use.
    static let deployCommands: [String: Set<String>] = [
        "pulumi": ["up", "update", "destroy", "import"],
        "terraform": ["apply", "destroy", "import"],
        "tofu": ["apply", "destroy", "import"],
        "terragrunt": ["apply", "destroy", "run-all"],
        "kubectl": ["apply", "create", "delete", "replace", "patch", "rollout", "scale", "set", "edit", "drain", "expose", "autoscale"],
        "oc": ["apply", "create", "delete", "replace", "patch", "rollout", "scale", "set", "edit"],
        "helm": ["install", "upgrade", "uninstall", "rollback", "delete"],
        "helmfile": ["apply", "sync", "destroy"],
        "cargo": ["publish"],
        "twine": ["upload"],
        "uv": ["publish"],
        "poetry": ["publish"],
        "hatch": ["publish"],
        "flit": ["publish"],
        "gem": ["push"],
        "fly": ["deploy", "launch", "scale", "secrets"],
        "flyctl": ["deploy", "launch", "scale", "secrets"],
        "firebase": ["deploy"],
        "wrangler": ["deploy", "publish"],
        "serverless": ["deploy", "remove"],
        "sls": ["deploy", "remove"],
        "cdk": ["deploy", "destroy"],
        "sam": ["deploy", "delete"],
        "eb": ["deploy"],
        "railway": ["up", "deploy", "redeploy"],
        "kamal": ["deploy", "redeploy", "rollback", "setup"],
        "copilot": ["deploy"],
        "ansible-playbook": [],
        "dokku": [],
    ]

    static let scriptRunners: Set<String> = ["make", "just", "task", "mage", "rake", "npm", "pnpm", "yarn", "bun", "cap"]

    static func isDeploy(program: String, tokens: [String], remote: Bool) -> Bool {
        let args = tokens.dropFirst().filter { !$0.hasPrefix("-") }
        let sub = args.first ?? ""
        if let subs = deployCommands[program] { return subs.isEmpty || subs.contains(sub) }
        switch program {
        case "docker", "podman":
            if sub == "push" || (sub == "stack" && args.dropFirst().first == "deploy") { return true }
            if ["buildx", "build"].contains(sub), tokens.contains("--push") { return true }
            if sub == "manifest", args.dropFirst().first == "push" { return true }
            if sub == "compose", args.contains("push") { return true }
            if remote, sub == "compose", args.contains(where: { ["up", "restart", "pull", "create"].contains($0) }) { return true }
            if remote, ["run", "restart", "start", "stop", "rm", "pull"].contains(sub) { return true }
            return false
        case "docker-compose":
            return args.contains("push") || (remote && args.contains(where: { ["up", "restart", "pull"].contains($0) }))
        case "npm", "pnpm", "yarn", "bun":
            if sub == "publish" || (sub == "npm" && args.dropFirst().first == "publish") { return true }
        case "vercel":
            return tokens.contains("--prod") || tokens.contains("--production") || ["promote", "rollback"].contains(sub)
        case "netlify":
            return sub == "deploy" && (tokens.contains("--prod") || tokens.contains("--production"))
        case "gcloud", "aws", "az":
            return args.contains { $0 == "deploy" || ["update-service", "update-function-code", "create-stack", "update-stack", "delete-stack"].contains($0) }
        case "systemctl", "service", "launchctl":
            return remote && args.contains { ["start", "restart", "reload", "stop", "enable", "disable", "load", "unload", "kickstart"].contains($0) }
        case "git":
            return false
        default:
            break
        }
        if scriptRunners.contains(program) {
            return args.contains { isDeployWord($0) }
        }
        return isDeployWord(program)
    }

    /// `deploy`, `release`, `publish` or `ship` as a word in a script name or
    /// target: `deploy.sh`, `deploy:prod`, `release-patch`.
    static func isDeployWord(_ word: String) -> Bool {
        word.lowercased().range(of: #"(^|[^a-z])(deploy|release|publish|ship)([^a-z]|$)"#, options: .regularExpression) != nil
    }

    // MARK: - ssh

    static func sshRemoteCommand(_ tokens: [String]) -> String? {
        let withValue: Set<String> = ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w", "-B"]
        var i = 1
        while i < tokens.count, tokens[i].hasPrefix("-") {
            if withValue.contains(tokens[i]) { i += 1 }
            i += 1
        }
        i += 1 // the host
        guard i < tokens.count else { return nil }
        return tokens[i...].joined(separator: " ")
    }

    static func isRemotePath(_ path: String) -> Bool {
        guard let colon = path.firstIndex(of: ":") else { return false }
        let host = path[..<colon]
        return !host.isEmpty && !host.contains("/")
    }

    // MARK: - Shell splitting

    /// Commands that run their arguments as another command.
    static let wrappers: Set<String> = ["sudo", "doas", "env", "nohup", "time", "command", "exec", "nice", "ionice", "xargs", "timeout", "caffeinate", "npx", "bunx", "pnpx", "watch"]

    /// The command a segment runs, without leading `VAR=value`s and wrappers.
    static func peel(_ tokens: [String]) -> [String] {
        var t = tokens[...]
        while let first = t.first {
            let name = (first as NSString).lastPathComponent
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                t = t.dropFirst()
            } else if name == "kv", t.dropFirst().first == "env", let dash = t.firstIndex(of: "--") {
                t = t[(dash + 1)...]
            } else if ["pnpm", "yarn"].contains(name), t.dropFirst().first == "dlx" {
                t = t.dropFirst(2)
            } else if wrappers.contains(name) {
                t = t.dropFirst()
                if name == "timeout", let next = t.first, !next.hasPrefix("-") { t = t.dropFirst() }
                while let flag = t.first, flag.hasPrefix("-") {
                    t = t.dropFirst()
                    if ["-u", "-g", "-n", "-s", "-k"].contains(flag), let value = t.first, !value.hasPrefix("-") { t = t.dropFirst() }
                }
            } else {
                break
            }
        }
        return Array(t)
    }

    /// The command line split into simple commands, each as its words with
    /// quotes removed. Heredoc bodies are skipped: they are data.
    static func segments(_ line: String) -> [[String]] {
        var result: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var heredocs: [String] = []
        let chars = Array(line)
        var i = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { result.append(words) }
            words = []
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count {
                    if chars[i + 1] != "\n" { word.append(chars[i + 1]); inWord = true }
                    i += 1
                }
            case "'":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
            case "\"":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) { i += 1 }
                    word.append(chars[i])
                    i += 1
                }
            case " ", "\t":
                endWord()
            case "\n":
                endSegment()
                if !heredocs.isEmpty {
                    // Skip each heredoc body up to its delimiter line.
                    for delimiter in heredocs {
                        while i + 1 < chars.count {
                            var end = i + 1
                            while end < chars.count, chars[end] != "\n" { end += 1 }
                            let bodyLine = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces)
                            i = end
                            if bodyLine == delimiter { break }
                        }
                    }
                    heredocs = []
                    continue
                }
            case ";", "&", "|", "(", ")", "`":
                endSegment()
            case "<" where i + 1 < chars.count && chars[i + 1] == "<":
                endWord()
                i += 2
                if i < chars.count, chars[i] == "<" { i += 1; continue } // here-string
                if i < chars.count, chars[i] == "-" { i += 1 }
                while i < chars.count, chars[i] == " " { i += 1 }
                var delimiter = ""
                while i < chars.count, !" \t\n;&|<>()".contains(chars[i]) {
                    if chars[i] != "'" && chars[i] != "\"" && chars[i] != "\\" { delimiter.append(chars[i]) }
                    i += 1
                }
                if !delimiter.isEmpty { heredocs.append(delimiter) }
                continue
            case ">", "<":
                // A redirection: drop it and its target (`2>&1`, `> out.log`).
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false } else { endWord() }
                i += 1
                while i < chars.count, ">&|".contains(chars[i]) { i += 1 }
                while i < chars.count, chars[i] == " " { i += 1 }
                while i < chars.count, !" \t\n;&|<>()".contains(chars[i]) { i += 1 }
                continue
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                endSegment()
                i += 1
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        endSegment()
        return result
    }
}
