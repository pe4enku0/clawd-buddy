import AppKit

enum Bridge {
    // A local Mach port lives in the user's own bootstrap namespace, so unlike a distributed
    // notification nobody else can listen in on what Claude Code is doing.
    static let portName = "com.clawdbuddy.app.events" as CFString
    static let bundleID = "com.clawdbuddy.app"
}

/// Reads the hook JSON from stdin, boils it down to a few strings and hands it to the app.
enum HookBridge {
    static func run() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if json["hook_event_name"] as? String == "PermissionRequest" {
            // Not worth launching the app for: it couldn't answer in time anyway.
            if !NSRunningApplication.runningApplications(withBundleIdentifier: Bridge.bundleID).isEmpty {
                requestApproval(json)
            }
            return
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: normalize(json)) else { return }
        if send(payload) { return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bridge.bundleID).isEmpty { launchApp() }
        // Give a freshly launched app a moment to open its port, so the event that woke it isn't lost.
        for _ in 0..<40 {
            usleep(100_000)
            if send(payload) { return }
        }
    }

    private static func send(_ payload: Data) -> Bool {
        guard let port = CFMessagePortCreateRemote(nil, Bridge.portName) else { return false }
        defer { CFMessagePortInvalidate(port) }
        return CFMessagePortSendRequest(port, 0, payload as CFData, 1, 0, nil, nil) == kCFMessagePortSuccess
    }

    /// Synchronous: waits for the notch buttons. Prints a decision only for an explicit Allow / Deny;
    /// otherwise prints nothing, so Claude Code asks in the terminal as usual.
    private static func requestApproval(_ j: [String: Any]) {
        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]
        let decision = ApprovalChannel.ask(ApprovalRequest(tool: tool, detail: approvalDetail(tool: tool, input: input)))
        let body: [String: Any]
        switch decision {
        case .allow: body = ["behavior": "allow"]
        case .deny: body = ["behavior": "deny", "message": "The user denied this from the Clawd Buddy notch."]
        case .terminal: return
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            FileHandle.standardOutput.write(data)
        }
    }

    /// Longer than `detail`: the card has room, and you should see what you're allowing.
    private static func approvalDetail(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash", "PowerShell":
            let lines = ((input["command"] as? String) ?? "").split(separator: "\n")
            let first = (lines.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            return truncate(lines.count > 1 ? first + " …" : first, 300)
        case "WebFetch":
            return truncate((input["url"] as? String) ?? "", 300)
        default:
            return detail(tool: tool, input: input)
        }
    }

    static func normalize(_ j: [String: Any]) -> [String: String] {
        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]
        var out: [String: String] = [
            "event": j["hook_event_name"] as? String ?? "",
            "tool": tool,
            "detail": detail(tool: tool, input: input),
        ]
        if let m = j["message"] as? String { out["message"] = m }
        if let k = j["notification_type"] as? String { out["kind"] = k }
        return out
    }

    private static func detail(tool: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        switch tool {
        case "Edit", "MultiEdit", "Write", "Read":
            return (str("file_path") as NSString).lastPathComponent
        case "NotebookEdit":
            return (str("notebook_path") as NSString).lastPathComponent
        case "Bash":
            let firstLine = str("command").split(separator: "\n").first.map(String.init) ?? ""
            return truncate(firstLine.trimmingCharacters(in: .whitespaces), 34)
        case "Grep", "Glob":
            return truncate(str("pattern"), 28)
        case "WebSearch":
            return truncate(str("query"), 30)
        case "WebFetch":
            return URL(string: str("url"))?.host ?? ""
        case "Agent", "Task":
            return truncate(str("description"), 30)
        default:
            // mcp__server__tool -> tool
            if tool.hasPrefix("mcp__") { return String(tool.split(separator: "_").last ?? "") }
            return tool
        }
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    private static func launchApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-a", Bundle.main.bundleURL.path]
        try? p.run()
        p.waitUntilExit()
    }
}
