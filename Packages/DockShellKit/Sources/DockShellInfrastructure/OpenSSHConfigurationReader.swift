import Darwin
import DockShellDomain
import Foundation

/// Bounded, static user-config reader. Never invokes ssh -G, a shell, DNS or Match exec.
/// Unknown semantics are reported rather than converted to an accidental direct connection.
public actor OpenSSHConfigurationReader: SSHConfigurationReading {
    private let home: URL
    private let localUser: String
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, localUser: String = NSUserName()) {
        self.home = home; self.localUser = localUser
    }

    public func read(from url: URL?) throws -> ServerImportDocument {
        var parser = ConfigurationParser(home: home, localUser: localUser)
        let nodes = try parser.load(url ?? home.appendingPathComponent(".ssh/config"))
        return try parser.evaluate(nodes)
    }
}

private indirect enum ConfigurationNode {
    case option(String, [String], String)
    case include([ConfigurationNode])
}

private struct ConfigurationParser {
    let home: URL
    let localUser: String
    private var bytesRead = 0
    private var fileCount = 0
    private var lineCount = 0
    private var stack: Set<String> = []
    private var aliases: [String] = []
    private var seenAliases: Set<String> = []
    private var hasMatch = false
    private var patternRules = 0

    init(home: URL, localUser: String) { self.home = home; self.localUser = localUser }

    mutating func load(_ url: URL) throws -> [ConfigurationNode] {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.contains("\0") else { throw ServerImportError.invalidPath }
        let path = url.resolvingSymlinksInPath().path
        guard !stack.contains(path) else { throw ServerImportError.includeCycle }
        guard stack.count < 16, fileCount < 128 else { throw ServerImportError.limitExceeded }
        stack.insert(path); fileCount += 1
        defer { stack.remove(path) }
        let text = try readFile(path)
        var result: [ConfigurationNode] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (offset, line) in lines.components(separatedBy: "\n").enumerated() {
            try Task.checkCancellation()
            lineCount += 1
            guard lineCount <= 20_000, line.utf8.count <= 8192 else { throw ServerImportError.limitExceeded }
            let location = url.lastPathComponent + ":" + String(offset + 1)
            let tokens: [String]
            do { tokens = try Self.tokenize(line) }
            catch { throw ServerImportError.invalidText }
            guard let key = tokens.first?.lowercased() else { continue }
            let values = Array(tokens.dropFirst())
            guard !values.isEmpty else { throw ServerImportError.invalidText }
            if key == "include" {
                for value in values {
                    // Dynamic include paths depend on host/Match evaluation. Do not guess.
                    guard !value.contains("%"), !value.contains("$"), !value.isEmpty else {
                        throw ServerImportError.invalidPath
                    }
                    let expanded = try expandHome(value)
                    let path = expanded.hasPrefix("/") ? expanded : home.appendingPathComponent(".ssh").appendingPathComponent(expanded).path
                    for included in try globPaths(path) { result.append(.include(try load(URL(fileURLWithPath: included)))) }
                }
            } else {
                if key == "match" { hasMatch = true }
                if key == "host" {
                    guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw ServerImportError.limitExceeded }
                    if values.contains(where: { $0.contains("*") || $0.contains("?") || $0.hasPrefix("!") }) { patternRules += 1 }
                    for value in values where !value.hasPrefix("!") && !value.contains("*") && !value.contains("?") {
                        if seenAliases.insert(value).inserted { aliases.append(value) }
                        guard aliases.count <= 1000 else { throw ServerImportError.limitExceeded }
                    }
                }
                result.append(.option(key, values, location))
            }
        }
        return result
    }

    private mutating func readFile(_ path: String) throws -> String {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ServerImportError.unreadable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ServerImportError.unreadable }
        guard info.st_size <= 2_000_000 else { throw ServerImportError.limitExceeded }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ServerImportError.unreadable }
            if count == 0 { break }
            bytesRead += count
            guard bytesRead <= 2_000_000 else { throw ServerImportError.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ServerImportError.invalidText }
        return text
    }

    /// Lexes only data. Quoted '#' and escaped quotes remain literal; '=' is a separator only after the keyword.
    private static func tokenize(_ line: String) throws -> [String] {
        var words: [String] = [], word = "", quoted = false, started = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\\" {
                guard let next = iterator.next() else { throw ServerImportError.invalidText }
                if next == "\"" || next == "\\" || next == " " || next == "#" { word.append(next) }
                else { word.append("\\"); word.append(next) }
                started = true; continue
            }
            if char == "\"" { quoted.toggle(); started = true; continue }
            if !quoted && char == "#" { break }
            if !quoted && (char == " " || char == "\t" || (char == "=" && words.isEmpty)) {
                if started { words.append(word); word = ""; started = false }
                continue
            }
            // An optional '=' following whitespace after the keyword is also a separator.
            if !quoted && char == "=" && words.count == 1 && !started { continue }
            word.append(char); started = true
        }
        guard !quoted else { throw ServerImportError.invalidText }
        if started { words.append(word) }
        return words
    }

    private func expandHome(_ path: String) throws -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        guard !path.hasPrefix("~") else { throw ServerImportError.invalidPath }
        return path
    }

    /// Avoid glob(3)'s unbounded result allocation. Directory visits and result count are capped.
    private func globPaths(_ pattern: String) throws -> [String] {
        var paths = ["/"], visits = 0
        for component in pattern.split(separator: "/").map(String.init) {
            var next: [String] = []
            for base in paths {
                try Task.checkCancellation()
                if component.contains("*") || component.contains("?") || component.contains("[") {
                    guard let dir = opendir(base) else { throw ServerImportError.unreadable }
                    defer { closedir(dir) }
                    while let entry = readdir(dir) {
                        visits += 1
                        guard visits <= 20_000 else { throw ServerImportError.limitExceeded }
                        let name = withUnsafePointer(to: entry.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                        }
                        if fnmatch(component, name, FNM_PERIOD) == 0 { next.append((base as NSString).appendingPathComponent(name)) }
                        guard next.count <= 128 else { throw ServerImportError.limitExceeded }
                    }
                } else {
                    let path = (base as NSString).appendingPathComponent(component)
                    var info = stat()
                    if lstat(path, &info) == 0 { next.append(path) }
                    else if errno != ENOENT && errno != ENOTDIR { throw ServerImportError.unreadable }
                }
            }
            paths = next.sorted()
        }
        return paths
    }

    func evaluate(_ nodes: [ConfigurationNode]) throws -> ServerImportDocument {
        var rows: [ServerImportRow] = []
        var steps = 0
        for alias in aliases {
            try Task.checkCancellation()
            var options: [String: String] = [:], identities: [String] = [], issues: [ServerImportIssue] = []
            var ignored: Set<String> = [], declared = false
            func visit(_ nodes: [ConfigurationNode], initiallyActive: Bool) throws {
                var active = initiallyActive
                for node in nodes {
                    steps += 1
                    guard steps <= 10_000_000 else { throw ServerImportError.limitExceeded }
                    if steps % 256 == 0 { try Task.checkCancellation() }
                    switch node {
                    case .include(let children):
                        // An inactive Include must not activate Host rules in its child.
                        if active { try visit(children, initiallyActive: true) }
                    case .option(let key, let args, let location):
                        if key == "host" {
                            active = Self.matches(alias, patterns: args)
                            if active && args.contains(alias) { declared = true }
                            continue
                        }
                        if key == "match" { active = false; continue }
                        guard active else { continue }
                        if key == "identityfile" {
                            if args.count != 1 { issues.append(.syntax(location)) }
                            else if !identities.contains(args[0]) { identities.append(args[0]) }
                        } else if ["hostname", "port", "user", "preferredauthentications", "pubkeyauthentication", "passwordauthentication"].contains(key) {
                            if args.count != 1 { issues.append(.syntax(location)) }
                            else if options[key] == nil { options[key] = args[0] }
                        } else if key == "identitiesonly" && ["yes", "no"].contains(args.first?.lowercased() ?? "") {
                            ignored.insert(key)
                        } else if Self.ignoredOptions.contains(key) {
                            ignored.insert(key)
                        } else if Self.noneOptions.contains(key) && args.count == 1 && ["no", "none"].contains(args[0].lowercased()) {
                            // These explicit disabled settings introduce no missing connection behavior.
                        } else if options[key] == nil {
                            options[key] = args.joined(separator: " ")
                            issues.append(.unsupported(key))
                        }
                    }
                }
            }
            try visit(nodes, initiallyActive: true)
            guard declared else { continue }
            // Match may affect previously declared hosts and can request another parse pass.
            // Until its semantics are supported, block the whole document's rows explicitly.
            if hasMatch { issues.append(.matchUnsupported) }
            let host: String
            do { host = try Self.expand(options["hostname"] ?? alias, tokens: ["h": alias, "n": alias]) }
            catch { host = alias; issues.append(.unsupported("hostname")) }
            let username = options["user"] ?? localUser
            if username.contains("%") || username.contains("$") { issues.append(.unsupported("user")) }
            var paths: [String] = []
            for identity in identities where identity.lowercased() != "none" {
                do {
                    let value = try Self.expand(identity, tokens: ["d": home.path, "u": localUser,
                        "h": host, "n": alias, "r": username, "p": options["port"] ?? "22"])
                    let path = try expandHome(value)
                    // Relative IdentityFile paths use the SSH process working directory. Never guess.
                    guard path.hasPrefix("/") else { throw ServerImportError.invalidPath }
                    if !paths.contains(path) { paths.append(path) }
                } catch { issues.append(.unsupported("identityfile")) }
            }
            let preferred = options["preferredauthentications"]?.lowercased()
            let kind: AuthenticationKind = !paths.isEmpty ? .privateKey :
                (preferred == "password" || options["pubkeyauthentication"]?.lowercased() == "no" ? .password : .agent)
            if options["preferredauthentications"] != nil { ignored.insert("preferredauthentications") }
            if options["pubkeyauthentication"] != nil { ignored.insert("pubkeyauthentication") }
            if options["passwordauthentication"] != nil { ignored.insert("passwordauthentication") }
            rows.append(ServerImportRow(name: alias, host: host, port: options["port"] ?? "22", username: username,
                authentication: kind, keyPaths: paths, issues: issues, ignoredOptions: ignored.sorted()))
        }
        return ServerImportDocument(rows: rows, patternRuleCount: patternRules)
    }

    private static let noneOptions: Set<String> = ["proxyjump", "proxycommand", "identityagent", "certificatefile",
        "canonicalizehostname", "remotecommand", "localcommand", "pkcs11provider", "securitykeyprovider", "knownhostscommand"]
    // These remain DockShell-controlled; preview lists each omitted option, never claiming a full config clone.
    private static let ignoredOptions: Set<String> = ["serveraliveinterval", "serveralivecountmax", "tcpkeepalive",
        "connecttimeout", "connectionattempts", "compression", "forwardagent", "forwardx11", "forwardx11trusted",
        "addkeystoagent", "usekeychain", "stricthostkeychecking", "userknownhostsfile", "globalknownhostsfile",
        "hashknownhosts", "checkhostip", "updatehostkeys", "sendenv", "setenv", "requesttty", "loglevel",
        "batchmode", "controlmaster", "controlpath", "controlpersist", "permitlocalcommand", "visualhostkey"]

    private static func expand(_ value: String, tokens: [Character: String]) throws -> String {
        guard !value.contains("$"), !value.contains("\0") else { throw ServerImportError.invalidPath }
        var result = "", iterator = value.makeIterator()
        while let char = iterator.next() {
            if char != "%" { result.append(char); continue }
            guard let token = iterator.next() else { throw ServerImportError.invalidPath }
            if token == "%" { result.append("%") }
            else if let replacement = tokens[token] { result += replacement }
            else { throw ServerImportError.invalidPath }
        }
        return result
    }

    /// SSH Host patterns support '*' and '?' (not filesystem bracket expressions).
    private static func matches(_ host: String, patterns: [String]) -> Bool {
        func match(_ pattern: String) -> Bool {
            if !pattern.contains("*") && !pattern.contains("?") { return host == pattern }
            let text = Array(host), pattern = Array(pattern)
            var i = 0, j = 0, star: Int?, retry = 0
            while i < text.count {
                if j < pattern.count && (pattern[j] == "?" || pattern[j] == text[i]) { i += 1; j += 1 }
                else if j < pattern.count && pattern[j] == "*" { star = j; j += 1; retry = i }
                else if let star { retry += 1; i = retry; j = star + 1 }
                else { return false }
            }
            while j < pattern.count && pattern[j] == "*" { j += 1 }
            return j == pattern.count
        }
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") { if match(String(pattern.dropFirst())) { return false } }
            else if match(pattern) { positive = true }
        }
        return positive
    }
}
