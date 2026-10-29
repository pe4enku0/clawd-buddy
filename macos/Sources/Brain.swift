import Foundation

/// Turns Claude Code hook events into moods and lines for the buddy.
final class Brain {
    private let view: BuddyView
    private let prefs: Prefs
    private var turnActive = false
    private var moodSince = Date()
    private var lastEventAt = Date()
    private var lastSayAt = Date.distantPast
    private var pending: (text: String, sticky: Bool)?
    private var bubbleHideAt: Date?
    private var nextIdleActAt = Date().addingTimeInterval(20)
    private var nextSleepTalkAt = Date().addingTimeInterval(40)
    private var editsThisTurn = 0
    private var activeSince: Date?
    private var turnStartedAt: Date?
    /// Edits and wall time of the last finished turn, for the notch's "Done" card.
    private(set) var lastTurn: (edits: Int, duration: TimeInterval) = (0, 0)
    private var demoTimers: [Timer] = []

    private static let minLineGap: TimeInterval = 1.1
    private static let streakMilestones: Set<Int> = [5, 10, 20, 30, 50, 100]

    init(view: BuddyView, prefs: Prefs) {
        self.view = view
        self.prefs = prefs
    }

    func greet() {
        view.jump(4)
        let hour = Calendar.current.component(.hour, from: Date())
        let timed: Phrase? = (5..<11).contains(hour) ? .greetMorning
            : (18..<23).contains(hour) ? .greetEvening
            : (hour >= 23 || hour < 5) ? .greetNight : nil
        sayNow(L10n.pick(timed.flatMap { Bool.random() ? $0 : nil } ?? .greeting))
    }

    func poked() {
        if view.mood == .sleeping { wakeUp(); sayNow(L10n.pick(.wake)) } else { sayNow(L10n.pick(.poke)) }
    }

    func dragStarted() {
        if view.mood == .sleeping { wakeUp() }
        sayNow(L10n.pick(.dragStart), sticky: true)
    }

    func dropped() { sayNow(L10n.pick(.dropped)) }

    func handle(_ info: [String: String]) {
        let now = Date()
        if activeSince == nil || now.timeIntervalSince(lastEventAt) > 15 * 60 { activeSince = now }
        lastEventAt = now
        let tool = info["tool"] ?? "", detail = info["detail"] ?? ""

        switch info["event"] ?? "" {
        case "SessionStart":
            set(.idle); view.jump(3)
            say(L10n.pick(.sessionStart))
        case "UserPromptSubmit":
            turnActive = true
            editsThisTurn = 0
            turnStartedAt = now
            set(.thinking); view.jump(2)
            let hour = Calendar.current.component(.hour, from: now)
            say(L10n.pick(hour < 5 && Double.random(in: 0..<1) < 0.25 ? .lateNight : .thinking))
        case "PreToolUse":
            turnActive = true
            if turnStartedAt == nil { turnStartedAt = now }
            toolStarted(tool, detail)
        case "PostToolUseFailure":
            set(.oops)
            say(L10n.pick(.oops))
        case "Stop":
            turnActive = false
            lastTurn = (editsThisTurn, now.timeIntervalSince(turnStartedAt ?? now))
            turnStartedAt = nil
            set(.done); view.jump(5)
            say(L10n.pick(.done))
            if let since = activeSince, now.timeIntervalSince(since) > 3600 {
                activeSince = now
                after(5) { self.say(L10n.pick(.breakReminder)) }
            }
        case "Notification":
            let msg = (info["message"] ?? "").lowercased(), kind = info["kind"] ?? ""
            set(.waiting)
            if kind.contains("permission") || msg.contains("permission") {
                say(L10n.pick(.waitingPermission), sticky: true)
            } else if kind.contains("idle") || msg.contains("waiting") {
                say(L10n.pick(.waitingIdle), sticky: true)
            } else {
                say(L10n.pick(.waitingGeneric), sticky: true)
            }
        default:
            break
        }
    }

    private func toolStarted(_ tool: String, _ detail: String) {
        let m = mood(for: tool)
        set(m)
        if m == .waiting {
            view.jump(3)
            say(L10n.pick(.waitingQuestion), sticky: true)
            return
        }
        if m == .writing {
            editsThisTurn += 1
            if Self.streakMilestones.contains(editsThisTurn) {
                view.jump(3)
                say(L10n.streak(editsThisTurn))
                return
            }
        }
        if m == .thinking, Bool.random() {
            say(L10n.pick(.planning)); return
        }
        if tool == "Bash", let special = bashPhrase(detail), Bool.random() {
            say(L10n.pick(special)); return
        }
        if let fun = funPhrase(for: m), Double.random(in: 0..<1) < prefs.chattiness {
            say(L10n.pick(fun)); return
        }
        say(L10n.action(tool: tool, detail: detail))
    }

    func tick() {
        let now = Date()
        if let p = pending, now.timeIntervalSince(lastSayAt) >= Self.minLineGap {
            pending = nil
            sayNow(p.text, sticky: p.sticky)
        }
        if let h = bubbleHideAt, now >= h {
            view.hideBubble()
            bubbleHideAt = nil
        }

        let inMood = now.timeIntervalSince(moodSince)
        switch view.mood {
        case .writing, .reading, .searching, .running, .web, .agent, .oops:
            if inMood > 6 { set(turnActive ? .thinking : .idle) }
        case .thinking:
            if inMood > 180 { turnActive = false; set(.idle) }
        case .done:
            if inMood > 10 { set(.idle) }
        case .waiting:
            if inMood > 120 { set(.sleeping); view.hideBubble(); bubbleHideAt = nil }
        case .idle:
            if now.timeIntervalSince(lastEventAt) > 120 {
                set(.sleeping)
                say(L10n.pick(.sleep))
                nextSleepTalkAt = now.addingTimeInterval(.random(in: 25...50))
            } else if prefs.idleChatter && !view.isActing && now >= nextIdleActAt {
                playIdleAct()
            }
        case .sleeping:
            if prefs.idleChatter && now >= nextSleepTalkAt {
                nextSleepTalkAt = now.addingTimeInterval(.random(in: 40...90))
                if Double.random(in: 0..<1) < 0.4 { sayNow(L10n.pick(.sleepTalk)) }
            }
        }
        view.step()
    }

    /// A scripted tour of every mood, for the menu / settings button.
    func demo() {
        demoTimers.forEach { $0.invalidate() }
        lastSayAt = .distantPast
        let script: [[String: String]] = [
            ["event": "UserPromptSubmit"],
            ["event": "PreToolUse", "tool": "Read", "detail": "App.swift"],
            ["event": "PreToolUse", "tool": "Grep", "detail": "func handle"],
            ["event": "PreToolUse", "tool": "Edit", "detail": "App.swift"],
            ["event": "PreToolUse", "tool": "Bash", "detail": "npm test"],
            ["event": "PostToolUseFailure", "tool": "Bash"],
            ["event": "PreToolUse", "tool": "WebSearch", "detail": "swift async"],
            ["event": "Notification", "kind": "permission_prompt"],
            ["event": "Stop"],
        ]
        for (i, ev) in script.enumerated() {
            after(Double(i) * 2.6) { self.handle(ev) }
        }
        after(Double(script.count) * 2.6 + 2) { self.view.play(.dance) }
    }

    // MARK: -

    private func playIdleAct() {
        nextIdleActAt = Date().addingTimeInterval(.random(in: 18...40))
        let a = Act.allCases.randomElement()!
        view.play(a)
        if Double.random(in: 0..<1) < 0.4 { say(L10n.pick(.idleQuip)) }
    }

    private func wakeUp() {
        set(.idle)
        lastEventAt = Date()
        nextIdleActAt = Date().addingTimeInterval(20)
        view.jump(2)
    }

    private func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: seconds, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        demoTimers.append(t)
        demoTimers.removeAll { !$0.isValid }
    }

    private func set(_ m: Mood) {
        view.setMood(m)
        moodSince = Date()
    }

    /// Rate-limited: a burst of tool calls shows the latest line instead of flickering through all of them.
    private func say(_ text: String, sticky: Bool = false) {
        if Date().timeIntervalSince(lastSayAt) < Self.minLineGap {
            pending = (text, sticky)
        } else {
            sayNow(text, sticky: sticky)
        }
    }

    private func sayNow(_ text: String, sticky: Bool = false) {
        lastSayAt = Date()
        pending = nil
        view.say(text)
        bubbleHideAt = sticky ? nil : Date().addingTimeInterval(3.5 + Double(text.count) * 0.05)
    }

    private func mood(for tool: String) -> Mood {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .writing
        case "Read": return .reading
        case "Grep", "Glob", "LS": return .searching
        case "Bash", "BashOutput", "PowerShell": return .running
        case "WebSearch", "WebFetch": return .web
        case "Agent", "Task": return .agent
        case "AskUserQuestion": return .waiting
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode": return .thinking
        default: return .running
        }
    }

    private func bashPhrase(_ cmd: String) -> Phrase? {
        let c = cmd.lowercased()
        func has(_ pattern: String) -> Bool { c.range(of: pattern, options: .regularExpression) != nil }
        if c.contains("git commit") { return .gitCommit }
        if c.contains("git push") { return .gitPush }
        if has(#"\b(test|tests|pytest|jest|vitest|xctest|rspec)\b"#) { return .tests }
        if has(#"\b(npm|pnpm|yarn|bun|pip3?|brew|cargo|gem|pod)\s+(install|add|i)\b"#) { return .installing }
        if has(#"\b(build|make|swiftc|xcodebuild|tsc|gradle|webpack|vite)\b"#) { return .building }
        if has(#"(^|[;&|]\s*)rm\s"#) { return .deleting }
        return nil
    }

    private func funPhrase(for m: Mood) -> Phrase? {
        switch m {
        case .writing: return .funWriting
        case .reading: return .funReading
        case .searching: return .funSearching
        case .running: return .funRunning
        case .web: return .funWeb
        case .agent: return .funAgent
        default: return nil
        }
    }
}
