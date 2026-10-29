import Foundation

/// Why a notch question didn't get an answer, in words for the user.
enum ChatFailure: Error {
    case notFound, notLoggedIn, offline, timeout
    case other(String)

    var message: String {
        let ru = L10n.lang == .ru
        switch self {
        case .notFound:
            return ru ? "Не нашёл Claude Code. Установи расширение Claude Code или CLI и попробуй снова."
                : "Couldn't find Claude Code. Install the Claude Code extension or CLI and try again."
        case .notLoggedIn:
            return ru ? "Claude Code не вошёл в аккаунт. Открой Claude Code и войди, потом спроси ещё раз."
                : "Claude Code isn't signed in. Open Claude Code, sign in, then ask again."
        case .offline:
            return ru ? "Нет связи с Claude. Проверь интернет и попробуй ещё раз."
                : "Can't reach Claude. Check your internet connection and try again."
        case .timeout:
            return ru ? "Claude слишком долго не отвечает. Попробуй ещё раз." : "Claude is taking too long. Try again."
        case .other(let detail):
            return (ru ? "Что-то пошло не так: " : "Something went wrong: ") + detail
        }
    }
}

/// Asks the local `claude -p` (the user's own login, no API key) with only the Read tool,
/// from a throwaway folder, streaming the answer. Marked with CLAWD_NOTCH_INTERNAL=1 so the
/// buddy's own hooks ignore it and the crab doesn't react to itself.
final class ClaudeRunner {
    static let internalEnv = "CLAWD_NOTCH_INTERNAL"
    private static let timeout: TimeInterval = 120
    private static let systemPrompt = """
        You are Clawd, a friendly pixel crab who lives in the MacBook notch and helps while the user codes. \
        Answer briefly and clearly: usually 1-4 sentences, at most a short list or a small code snippet. \
        Plain text; use Markdown only for `code`. Reply in the language of the user's message. \
        You can only read files, never change anything or run commands.
        """

    private var process: Process?
    private var workDir: URL?
    private var generation = 0

    /// CLI installs first, then the newest copy bundled with an editor extension.
    static func locate() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for editor in [".vscode-oss", ".vscode", ".vscode-insiders", ".cursor", ".windsurf"] {
            let dir = "\(home)/\(editor)/extensions"
            let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasPrefix("anthropic.claude-code-") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += names.map { "\(dir)/\($0)/resources/native-binary/claude" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `onText` gets the whole answer so far; both callbacks run on the main queue.
    /// `files` are copied into the run's folder so Read can reach them.
    func ask(_ prompt: String, files: [URL] = [], onText: @escaping (String) -> Void,
             onDone: @escaping (Result<String, ChatFailure>) -> Void) {
        cancel()
        generation += 1
        let gen = generation
        guard let claude = Self.locate() else { onDone(.failure(.notFound)); return }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClawdNotch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try? FileManager.default.copyItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent)) }
        workDir = dir

        let p = Process()
        p.executableURL = claude
        p.currentDirectoryURL = dir
        p.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--tools", "Read", "--allowedTools", "Read", "--permission-mode", "dontAsk",
                       "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands",
                       "--model", "sonnet", "--system-prompt", Self.systemPrompt]
        var env = ProcessInfo.processInfo.environment
        env[Self.internalEnv] = "1"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Output is parsed on the main queue, in arrival order.
        var text = "", final: String?, failure: String?, errText = "", pending = Data()
        func consume(_ chunk: Data) {
            pending.append(chunk)
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let j = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                switch j["type"] as? String {
                case "stream_event":
                    let e = j["event"] as? [String: Any], d = e?["delta"] as? [String: Any]
                    if e?["type"] as? String == "content_block_delta", d?["type"] as? String == "text_delta",
                       let t = d?["text"] as? String, generation == gen {
                        text += t
                        onText(text)
                    }
                case "result":
                    let r = j["result"] as? String ?? ""
                    if j["is_error"] as? Bool == true || (j["subtype"] as? String ?? "success") != "success" {
                        failure = r.isEmpty ? (j["subtype"] as? String ?? "error") : r
                    } else {
                        final = r
                    }
                default:
                    break
                }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { DispatchQueue.main.async { consume(chunk) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { DispatchQueue.main.async { errText += String(decoding: chunk, as: UTF8.self) } }
        }
        p.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stdout.fileHandleForReading.readDataToEndOfFile() + Data("\n".utf8)
            DispatchQueue.main.async {
                consume(rest)
                guard let self, self.generation == gen else { return }
                self.cleanUp()
                if let final, !final.isEmpty { onDone(.success(final)) }
                else if let failure { onDone(.failure(Self.classify(failure))) }
                else if !text.isEmpty { onDone(.success(text)) }
                else { onDone(.failure(Self.classify(errText.isEmpty ? "exit \(proc.terminationStatus)" : errText))) }
            }
        }

        do {
            try p.run()
        } catch {
            cleanUp()
            onDone(.failure(.notFound))
            return
        }
        process = p
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, self.generation == gen, self.process?.isRunning == true else { return }
            self.cancel()
            onDone(.failure(.timeout))
        }
    }

    /// Stops the current question; its callbacks won't fire any more.
    func cancel() {
        generation += 1
        if let p = process, p.isRunning { p.terminate() }
        cleanUp()
    }

    private func cleanUp() {
        process = nil
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
    }

    static func classify(_ raw: String) -> ChatFailure {
        let s = raw.lowercased()
        let has = { (words: [String]) in words.contains { s.contains($0) } }
        if has(["/login", "log in", "logged in", "not authenticated", "authentication", "oauth", "401", "api key"]) {
            return .notLoggedIn
        }
        if has(["network", "enotfound", "econnrefused", "econnreset", "fetch failed", "getaddrinfo",
                "connection error", "unable to connect", "offline", "etimedout"]) {
            return .offline
        }
        let line = raw.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? raw
        return .other(line.count > 160 ? String(line.prefix(159)) + "…" : line)
    }
}
