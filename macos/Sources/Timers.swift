import Foundation

/// A countdown or reminder set from the notch chat. Persisted, so it survives a restart.
struct ClawdTimer: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var fireAt: Date
    /// Length when it was set as a countdown ("10 min"); nil for "at 15:30".
    var duration: TimeInterval?
}

/// What a chat message asks for, when it is a timer command rather than a question.
enum TimerCommand: Equatable {
    case set(fireAt: Date, label: String, duration: TimeInterval?)
    /// A timer request we couldn't read ourselves ("the day after tomorrow in the morning"): Claude parses it.
    case needsHelp(String)
    case cancel(all: Bool)
    case list
}

final class Timers {
    private(set) var items: [ClawdTimer] = []
    private let key = "timers"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ClawdTimer].self, from: data) { items = saved }
    }

    @discardableResult
    func add(fireAt: Date, label: String, duration: TimeInterval?) -> ClawdTimer {
        let t = ClawdTimer(id: UUID(), label: label, fireAt: fireAt, duration: duration)
        items.append(t)
        items.sort { $0.fireAt < $1.fireAt }
        save()
        return t
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        items = []
        save()
    }

    /// Timers whose time has come, taken off the list.
    func popDue(_ now: Date = Date()) -> [ClawdTimer] {
        let due = items.filter { $0.fireAt <= now }
        guard !due.isEmpty else { return [] }
        items.removeAll { $0.fireAt <= now }
        save()
        return due
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Reads timer commands in Russian and English. Only imperative phrasing counts, so a question like
/// "how do I make a timer in JS for 5 seconds?" stays a question.
enum TimerParser {
    private static let setTrigger = #"^(?:(?:clawd|клод|краб)[,!]?\s+)?(?:пожалуйста\s+|please\s+)?(?:(?:поставь|заведи|установи|включи|запусти|сделай)\s+(?:мне\s+)?(?:таймер|будильник|напоминание)|таймер|будильник|напомни(?:ть)?(?:\s+мне)?|разбуди(?:\s+меня)?|(?:set|start)\s+(?:a\s+|an\s+|the\s+)?(?:timer|alarm|reminder)|timer|alarm|remind\s+me|wake\s+me(?:\s+up)?)\b"#
    private static let cancelTrigger = #"^(?:отмени|удали|сбрось|выключи|останови|убери|cancel|stop|delete|clear|remove)\s+(?:(все|all)\s+)?(?:мои\s+|my\s+|the\s+)?(?:таймер|будильник|напоминани|timer|alarm|reminder)"#
    private static let listTrigger = #"^(?:сколько\s+(?:ещё|еще)?\s*осталось|какие\s+(?:у\s+меня\s+)?таймеры|мои\s+таймеры|покажи\s+таймеры|how\s+much\s+time\s+(?:is\s+)?left|list\s+(?:my\s+)?timers|my\s+timers|show\s+(?:my\s+)?timers)"#

    private static let numberWords: [String: Int] = [
        "одну": 1, "одна": 1, "один": 1, "две": 2, "два": 2, "три": 3, "четыре": 4, "пять": 5, "шесть": 6,
        "семь": 7, "восемь": 8, "девять": 9, "десять": 10, "пятнадцать": 15, "двадцать": 20, "тридцать": 30,
        "сорок": 40, "пятьдесят": 50, "пару": 2, "пара": 2,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "a": 1, "an": 1,
    ]

    /// Fixed phrases first ("полчаса" would otherwise read as "час").
    private static let phrases: [(String, TimeInterval)] = [
        ("полтора часа", 5400), ("полчаса", 1800), ("четверть часа", 900), ("half an hour", 1800),
        ("quarter of an hour", 900), ("an hour and a half", 5400),
    ]

    private static let unitPattern = #"(\d+(?:[.,]\d+)?)\s*(секунд[уы]?|сек\.?|с\b|минут[уы]?|мин\.?|м\b|час(?:а|ов)?|ч\b|seconds?|secs?|s\b|minutes?|mins?|m\b|hours?|hrs?|h\b)"#
    private static let barePattern = #"(?:через|in|for|на)\s+(минуту|час|секунду|a minute|an hour|a second)\b"#
    private static let clockPattern = #"(?:\bв|\bat|\bна)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|утра|вечера|дня)?\b"#

    static func parse(_ text: String, now: Date = Date()) -> TimerCommand? {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let m = match(cancelTrigger, s) { return .cancel(all: m.range(at: 1).location != NSNotFound) }
        if match(listTrigger, s) != nil { return .list }
        guard let trigger = match(setTrigger, s) else { return nil }
        var rest = String(s[Range(trigger.range, in: s)!.upperBound...])

        var seconds: TimeInterval = 0
        var spans: [NSRange] = []
        for (phrase, value) in phrases where rest.contains(phrase) {
            seconds += value
            rest = rest.replacingOccurrences(of: phrase, with: " ")
        }
        rest = replaceNumberWords(rest)
        for m in all(unitPattern, rest) {
            let n = Double(sub(rest, m.range(at: 1)).replacingOccurrences(of: ",", with: ".")) ?? 0
            let unit = sub(rest, m.range(at: 2))
            seconds += n * (unit.hasPrefix("с") || unit.hasPrefix("s") ? 1 : unit.hasPrefix("ч") || unit.hasPrefix("h") ? 3600 : 60)
            spans.append(m.range)
        }
        for m in all(barePattern, rest) {
            let w = sub(rest, m.range(at: 1))
            seconds += w.contains("час") || w.contains("hour") ? 3600 : w.contains("мин") || w.contains("minute") ? 60 : 1
            spans.append(m.range)
        }

        var fireAt: Date?
        var duration: TimeInterval?
        if seconds > 0 {
            fireAt = now.addingTimeInterval(seconds)
            duration = seconds
        } else if let m = all(clockPattern, rest).first, let at = clockTime(rest, m, now: now) {
            fireAt = at
            spans.append(m.range)
        }
        guard let fireAt else { return .needsHelp(text) }
        // The label was found in lowercase; take the same words from the original to keep its case.
        var label = label(from: rest, removing: spans)
        if !label.isEmpty, let r = text.range(of: label, options: .caseInsensitive) {
            label = String(text[r])
            label = label.prefix(1).uppercased() + label.dropFirst()
        }
        return .set(fireAt: fireAt, label: label, duration: duration)
    }

    /// "15:30", "at 3pm", "в 7 утра": today, or tomorrow if that time has passed.
    private static func clockTime(_ s: String, _ m: NSTextCheckingResult, now: Date) -> Date? {
        guard var hour = Int(sub(s, m.range(at: 1))), hour < 24 else { return nil }
        let minute = m.range(at: 2).location != NSNotFound ? Int(sub(s, m.range(at: 2))) ?? 0 : 0
        let suffix = m.range(at: 3).location != NSNotFound ? sub(s, m.range(at: 3)) : ""
        // "в 5" without minutes or am/pm is too vague ("в 5 раз"?): only accept clear times.
        guard m.range(at: 2).location != NSNotFound || !suffix.isEmpty else { return nil }
        if ["pm", "вечера", "дня"].contains(suffix), hour < 12 { hour += 12 }
        if ["am", "утра"].contains(suffix), hour == 12 { hour = 0 }
        guard minute < 60 else { return nil }
        let cal = Calendar.current
        var at = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if at <= now { at = cal.date(byAdding: .day, value: 1, to: at) ?? at }
        return at
    }

    /// What's left once the time is cut out: "выпить воды" from "через 20 минут выпить воды".
    private static func label(from s: String, removing spans: [NSRange]) -> String {
        var t = s as NSString
        for r in spans.sorted(by: { $0.location > $1.location }) { t = t.replacingCharacters(in: r, with: " ") as NSString }
        let filler: Set<String> = ["через", "на", "в", "in", "for", "at", "to", "about", "that", "чтобы", "что", "о", "об", "про", "мне", "me", "and", "и"]
        var words = (t as String).split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        while let f = words.first, filler.contains(f) { words.removeFirst() }
        while let l = words.last, filler.contains(l) { words.removeLast() }
        let label = words.joined(separator: " ")
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private static func replaceNumberWords(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            numberWords[String(w)].map(String.init) ?? String(w)
        }.joined(separator: " ")
    }

    private static func match(_ pattern: String, _ s: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func all(_ pattern: String, _ s: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: s, range: NSRange(s.startIndex..., in: s))) ?? []
    }

    private static func sub(_ s: String, _ r: NSRange) -> String {
        Range(r, in: s).map { String(s[$0]) } ?? ""
    }
}

extension TimerParser {
    /// Instructions for Claude when we couldn't read a timer request ourselves.
    static func helpPrompt(_ message: String, now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return """
            Right now it is \(f.string(from: now)) (local time zone \(TimeZone.current.identifier)). \
            If the user's message below asks to set a timer, alarm or reminder, reply with exactly one line and nothing else: \
            TIMER {"fire_at": "<ISO 8601 with offset>", "label": "<what to remind about, in the user's language, or empty>"} \
            If it is not such a request, answer it normally instead.

            User's message: \(message)
            """
    }

    /// Reads Claude's `TIMER {...}` line; nil if the answer is something else.
    static func parseHelp(_ answer: String) -> (fireAt: Date, label: String)? {
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("TIMER"), let brace = t.firstIndex(of: "{"),
              let json = (try? JSONSerialization.jsonObject(with: Data(t[brace...].utf8))) as? [String: Any],
              let at = (json["fire_at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }),
              at > Date() else { return nil }
        return (at, (json["label"] as? String) ?? "")
    }
}

/// How times read in the notch.
enum TimerFormat {
    /// Wing countdown, short enough for ~44 pt: "9:59", "59:59", "1ч05" / "1h05".
    static func compact(_ left: TimeInterval) -> String {
        let s = max(0, Int(left.rounded(.up)))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: L10n.lang == .ru ? "%dч%02d" : "%dh%02d", s / 3600, s / 60 % 60)
    }

    /// "1:05:00" / "9:59" for the hover list.
    static func left(_ left: TimeInterval) -> String {
        let s = max(0, Int(left.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "10 мин", "1 ч 30 мин", "45 сек".
    static func length(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        let ru = L10n.lang == .ru
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) " + (ru ? "ч" : "h")) }
        if m > 0 { parts.append("\(m) " + (ru ? "мин" : "min")) }
        if sec > 0 && h == 0 { parts.append("\(sec) " + (ru ? "сек" : "s")) }
        return parts.isEmpty ? (ru ? "0 сек" : "0 s") : parts.joined(separator: " ")
    }

    /// Stopwatch time: "1:23", "1:02:03", with tenths when asked ("1:23.4").
    static func elapsed(_ t: TimeInterval, tenths: Bool = false) -> String {
        let s = Int(max(0, t))
        let base = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        return tenths ? base + ".\(Int(max(0, t) * 10) % 10)" : base
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (L10n.lang == .ru ? "d MMM, HH:mm" : "MMM d, HH:mm")
        f.locale = Locale(identifier: L10n.lang == .ru ? "ru_RU" : "en_US")
        return f.string(from: d)
    }
}

/// One stopwatch. Persisted, so a restart doesn't lose the time.
struct Stopwatch: Codable, Equatable {
    /// Time from earlier runs, before the last pause.
    var accumulated: TimeInterval = 0
    /// Set while running.
    var startedAt: Date?

    var isRunning: Bool { startedAt != nil }

    func elapsed(_ now: Date = Date()) -> TimeInterval {
        accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    private static let key = "stopwatch"

    static func load() -> Stopwatch? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Stopwatch.self, from: $0) }
    }

    static func save(_ s: Stopwatch?) {
        if let s, let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

enum StopwatchCommand: Equatable { case start, pause, resume, reset, show }

/// Stopwatch commands, RU and EN. Like timers, only commands count, not questions about stopwatches.
enum StopwatchParser {
    private static let lead = #"^(?:(?:clawd|клод|краб)[,!]?\s+)?(?:пожалуйста\s+|please\s+)?"#
    private static let noun = #"(?:секундомер\w*|stopwatch)"#
    private static let rules: [(StopwatchCommand, String)] = [
        (.pause, #"(?:останови|стоп|пауза|поставь\s+на\s+паузу|приостанови|pause|stop)\s+(?:the\s+)?"# + noun),
        (.resume, #"(?:продолжи|возобнови|сними\s+с\s+паузы|resume|continue|unpause)\s+(?:the\s+)?"# + noun),
        (.reset, #"(?:сбрось|обнули|удали|убери|reset|clear|cancel)\s+(?:the\s+)?"# + noun),
        (.show, #"(?:сколько\s+прошло|сколько\s+на\s+секундомере|how\s+long\s+has\s+it\s+been|stopwatch\s+time)"#),
        (.start, #"(?:(?:запусти|включи|поставь|начни|заведи|start|run)\s+(?:a\s+|the\s+)?"# + noun + #"|"# + noun
            + #"|засеки(?:\s+время)?|time\s+me|start\s+timing)$"#),
    ]

    static func parse(_ text: String) -> StopwatchCommand? {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for (command, body) in rules
        where (try? NSRegularExpression(pattern: lead + body))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return command
        }
        return nil
    }
}
