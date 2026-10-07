// The day coach: work time, water and rest reminders, lunch, the end of the day, and today's numbers.
// Work time counts only while Claude is busy or you sent a prompt in the last 5 minutes.
import AppKit
import Foundation

let stackDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stack")
let dayConfigURL = stackDir.appendingPathComponent("day.json")
let daysDir = stackDir.appendingPathComponent("days")

/// Shared with day-hook.sh, so both read the same hours.
struct DayConfig: Codable {
    var start = "09:30"
    var end = "18:30"
    var checkFrom = "18:00"      // new tasks after this get a time check
    var lunchStart = "13:00"
    var lunchEnd = "13:45"
    var waterMinutes = 60
    var restMinutes = 120
    var workdays = [2, 3, 4, 5, 6]   // Calendar weekdays: 1 is Sunday, so Monday to Friday

    static func load() -> DayConfig {
        if let d = try? Data(contentsOf: dayConfigURL), let c = try? JSONDecoder().decode(DayConfig.self, from: d) { return c }
        let c = DayConfig()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: stackDir, withIntermediateDirectories: true)
        try? enc.encode(c).write(to: dayConfigURL)
        return c
    }

    /// "18:30" today as a date.
    func time(_ hm: String, on day: Date) -> Date {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: day) ?? day
    }
}

enum Reminder: Equatable {
    case water, rest, lunch, windDown(minutesLeft: Int), dayDone, overtime(minutes: Int)
}

struct DaySummary {
    var prompts = 0, tasksDone = 0, agents = 0, water = 0, breaks = 0
    var workSecs: Double = 0
}

final class DayCoach: ObservableObject {
    @Published var reminder: Reminder?
    @Published var summary = DaySummary()
    @Published var phase = "before"          // before, working, windDown, done, off
    @Published var dayFraction: Double = 0   // 0 at start, 1 at end
    @Published var waterFraction: Double = 0 // fills up to the next water reminder
    @Published var restFraction: Double = 0
    @Published var minutesLeft = 0

    var config = DayConfig.load()
    var soundOn = UserDefaults.standard.object(forKey: "coachSound") as? Bool ?? true
    private let d: UserDefaults
    /// Tests pass their own store and no log, so they never touch the real numbers.
    private let useLog: Bool

    init(store: UserDefaults = .standard, useLog: Bool = true) {
        d = store
        self.useLog = useLog
    }
    private var timer: Timer?
    private var lastTick: Date?
    private var idleSince: Date?
    private var snoozedUntil: Date?
    private var answeredAt: Date?
    private var day = ""

    // Saved per day, so a restart keeps the numbers.
    private func key(_ k: String) -> String { "coach.\(day).\(k)" }
    private var workSecs: Double { get { d.double(forKey: key("work")) } set { d.set(newValue, forKey: key("work")) } }
    private var waterAt: Double { get { d.double(forKey: key("waterAt")) } set { d.set(newValue, forKey: key("waterAt")) } }
    private var restAt: Double { get { d.double(forKey: key("restAt")) } set { d.set(newValue, forKey: key("restAt")) } }
    private func flag(_ k: String) -> Bool { d.bool(forKey: key(k)) }
    private func setFlag(_ k: String) { d.set(true, forKey: key(k)) }
    private func count(_ k: String) -> Int { d.integer(forKey: key(k)) }
    private func bump(_ k: String) { d.set(count(k) + 1, forKey: key(k)) }

    /// Today only. day-hook.sh reads the same switch as a file: days/<date>.off
    var dayOff: Bool {
        get { flag("off") }
        set {
            d.set(newValue, forKey: key("off"))
            let f = daysDir.appendingPathComponent("\(day).off")
            if newValue {
                try? FileManager.default.createDirectory(at: daysDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: f.path, contents: nil)
            } else {
                try? FileManager.default.removeItem(at: f)
            }
            objectWillChange.send()
            tick(busy: false)
        }
    }

    func save(_ c: DayConfig) {
        config = c
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: dayConfigURL)
        tick(busy: false)
    }

    /// `busy` is true while any Claude session is running or waiting for you.
    func tick(busy: Bool, now: Date = Date()) {
        let today = Self.dayString(now)
        if today != day { day = today; reminder = nil; snoozedUntil = nil; idleSince = nil; answeredAt = nil }
        let dt = lastTick.map { max(0, min(now.timeIntervalSince($0), 30)) } ?? 0   // the Mac may have slept
        lastTick = now

        let log = useLog ? readLog(today) : Log()
        let recentPrompt = log.lastPrompt.map { now.timeIntervalSince1970 - $0 < 300 } ?? false
        let active = busy || recentPrompt
        if active {
            workSecs += dt
            idleSince = nil
        } else {
            if idleSince == nil { idleSince = now }
            // Five quiet minutes count as a break: the rest counter starts again.
            if let s = idleSince, now.timeIntervalSince(s) >= 300, workSecs - restAt > 60 {
                restAt = workSecs
                bump("breaks")
            }
        }

        let weekday = Calendar.current.component(.weekday, from: now)
        let start = config.time(config.start, on: now), end = config.time(config.end, on: now)
        let checkFrom = config.time(config.checkFrom, on: now)
        let workday = config.workdays.contains(weekday) && !dayOff
        minutesLeft = max(0, Int(end.timeIntervalSince(now) / 60))
        dayFraction = max(0, min(1, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
        waterFraction = min(1, (workSecs - waterAt) / Double(config.waterMinutes * 60))
        restFraction = min(1, (workSecs - restAt) / Double(config.restMinutes * 60))
        summary = DaySummary(prompts: log.prompts, tasksDone: log.stops, agents: log.agents,
                             water: count("water"), breaks: count("breaks"), workSecs: workSecs)

        if !workday { phase = "off" }
        else if now < start { phase = "before" }
        else if now < checkFrom { phase = "working" }
        else if now < end { phase = "windDown" }
        else { phase = "done" }

        let next = pick(now: now, workday: workday, active: active, end: end)
        if next != reminder {
            if let next, soundOn, !isSame(next, reminder) { NSSound(named: "Tink")?.play() }
            reminder = next
        }
    }

    /// One reminder at a time, the most important first.
    private func pick(now: Date, workday: Bool, active: Bool, end: Date) -> Reminder? {
        // Weekends and days off: no reminders at all.
        guard workday else { return nil }
        if let s = snoozedUntil, now < s { return nil }
        if phase == "done" {
            if !flag("dayDoneSeen") { return .dayDone }
            // After the day: a gentle note every 15 minutes, only while you keep working.
            let past = Int(now.timeIntervalSince(end) / 60)
            if active, past >= 15, past / 15 > count("overtimeSeen") { return .overtime(minutes: past) }
            return nil
        }
        if phase == "windDown" && !flag("windDownSeen") { return .windDown(minutesLeft: minutesLeft) }
        let lunchStart = config.time(config.lunchStart, on: now), lunchEnd = config.time(config.lunchEnd, on: now)
        let lunch = now >= lunchStart && now < lunchEnd
        if lunch { return flag("lunchSeen") ? nil : .lunch }
        // After you answer one reminder, the next water or rest waits at least 15 minutes.
        if let a = answeredAt, now.timeIntervalSince(a) < 900 { return nil }
        if restFraction >= 1 { return .rest }
        if waterFraction >= 1 { return .water }
        return nil
    }

    private func isSame(_ a: Reminder, _ b: Reminder?) -> Bool {
        switch (a, b) {
        case (.windDown, .windDown?), (.overtime, .overtime?): return true
        default: return a == b
        }
    }

    // MARK: - Buttons

    func done() {
        guard let r = reminder else { return }
        switch r {
        case .water: waterAt = workSecs; bump("water")
        case .rest: restAt = workSecs; bump("breaks")
        case .lunch: setFlag("lunchSeen"); restAt = workSecs
        case .windDown: setFlag("windDownSeen")
        case .dayDone: setFlag("dayDoneSeen")
        case .overtime: bump("overtimeSeen")
        }
        reminder = nil
        answeredAt = lastTick ?? Date()
        tick(busy: false, now: lastTick ?? Date())
    }

    func later() {
        snoozedUntil = Date().addingTimeInterval(600)
        reminder = nil
    }

    // MARK: - Today's log, written by stack-hook.sh

    struct Log { var prompts = 0, stops = 0, agents = 0; var lastPrompt: Double? }
    private var logCache: (String, Date?, Log)?

    private func readLog(_ day: String) -> Log {
        let url = daysDir.appendingPathComponent("\(day).jsonl")
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let c = logCache, c.0 == day, c.1 == mtime { return c.2 }
        var log = Log()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch o["e"] as? String {
            case "prompt": log.prompts += 1; log.lastPrompt = o["t"] as? Double
            case "stop": log.stops += 1
            case "agent": log.agents += 1
            default: break
            }
        }
        logCache = (day, mtime, log)
        return log
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

func hm(_ secs: Double) -> String {
    let m = Int(secs / 60)
    return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
}
