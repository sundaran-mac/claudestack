// The day coach: work time, water and rest reminders, lunch, the end of the day, and today's numbers.
// The day starts at a fixed time, or (the default) at your first use after midnight: keyboard or
// mouse while the screen is on, a prompt, a new Claude session, or opening Ghostty. It ends after your work hours plus lunch.
// Work time counts while you work with Claude: any keyboard or mouse input in the last 5 minutes,
// a prompt in the last 5 minutes (from the phone too), or a session that is running. Watching an
// agent for 40 minutes is work. Going for lunch stops it, even while agents run.
// Ten minutes with no input, no prompt and nothing running is a break. A shorter pause stops work
// time but is not a rest, so the rest timer keeps going.
import AppKit
import CoreGraphics
import Foundation

/// Seconds since the last keyboard or mouse input anywhere on the Mac. Needs no permission.
/// While nobody can use the Mac (screen off or locked) it is never "just now": a dark wake, when
/// the lid is shut and macOS wakes for a few seconds to fetch mail or back up, resets this clock.
/// On 2026-10-15 a dark wake at 00:04 started the day, so it "ended" at 08:03.
func userIdleSeconds() -> Double {
    inputIdle(raw: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!),
              screenInUse: screenInUse())
}

/// The idle clock only means something when a person can see the screen.
func inputIdle(raw: Double, screenInUse: Bool) -> Double { screenInUse ? raw : .infinity }

/// The main display is awake and the session is on screen and unlocked. In a dark wake the
/// display stays asleep, so this is false.
func screenInUse() -> Bool {
    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
    guard let s = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    if (s["CGSSessionScreenIsLocked"] as? Bool) == true { return false }
    return (s[kCGSessionOnConsoleKey as String] as? Bool) ?? true
}

/// Claude is working for you: a session is running, or asked you something under 10 minutes
/// ago. "Maybe stuck" and a question left for an hour do not count.
func claudeWorking(_ rows: [Row], now: Double) -> Bool {
    rows.contains { $0.display == .running || ($0.display == .needs && now - $0.since < 600) }
}

/// When Ghostty started, if it is open. The day can start then.
func ghosttyOpened() -> Date? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").compactMap(\.launchDate).min()
}

/// No input for this long and work time stops counting.
let activeWithin: Double = 300
/// No input for this long is a real break, and the rest timer starts again. Five minutes was too
/// short: reading an answer or a call reset the timer many times a day, so rest never came.
let breakAfter: Double = 600
/// With "Find my start time automatically", the day resets at midnight and your first use after
/// it starts the new day (Sundaran's choice, 2026-10-14). A running agent alone does not start it.
let earliestStartHour = 0
/// "I'm back" comes by itself on the first keyboard or mouse use after this much lunch.
let lunchAutoBack: Double = 600
/// The time check for new tasks starts this many minutes before an automatic day ends.
let autoCheckMinutes = 30

let stackDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stack")
let dayConfigURL = stackDir.appendingPathComponent("day.json")
let daysDir = stackDir.appendingPathComponent("days")

/// Shared with day-hook.sh, so both read the same hours.
struct DayConfig: Codable, Equatable {
    var autoStart = true         // the day starts at your first input; start, end and checkFrom are not used
    var workMinutes = 480        // with autoStart: the length of the day, lunch not counted
    var start = "09:30"
    var end = "18:30"
    var checkFrom = "18:00"      // new tasks after this get a time check
    var lunchStart = "13:00"
    var lunchEnd = "13:45"
    var waterMinutes = 60
    var restMinutes = 120
    var workdays = [2, 3, 4, 5, 6]   // Calendar weekdays: 1 is Sunday, so Monday to Friday

    init() {}

    /// A missing key keeps its default. Without this, a day.json saved by an older build fails to
    /// read, and load() writes the defaults over the hours you set.
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        let d = DayConfig()
        autoStart = try k.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
        workMinutes = try k.decodeIfPresent(Int.self, forKey: .workMinutes) ?? d.workMinutes
        start = try k.decodeIfPresent(String.self, forKey: .start) ?? d.start
        end = try k.decodeIfPresent(String.self, forKey: .end) ?? d.end
        checkFrom = try k.decodeIfPresent(String.self, forKey: .checkFrom) ?? d.checkFrom
        lunchStart = try k.decodeIfPresent(String.self, forKey: .lunchStart) ?? d.lunchStart
        lunchEnd = try k.decodeIfPresent(String.self, forKey: .lunchEnd) ?? d.lunchEnd
        waterMinutes = try k.decodeIfPresent(Int.self, forKey: .waterMinutes) ?? d.waterMinutes
        restMinutes = try k.decodeIfPresent(Int.self, forKey: .restMinutes) ?? d.restMinutes
        workdays = try k.decodeIfPresent([Int].self, forKey: .workdays) ?? d.workdays
    }

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

    /// With autoStart: the end of a day that started at `start`. Lunch is not work time, so the
    /// part of lunch after the start is added. A day that ends before lunch skips it.
    /// `lunchSecs`: the real lunch, once you used "Going for lunch". It replaces the lunch hours.
    func autoEnd(from start: Date, lunchSecs: Double? = nil) -> Date {
        let work = Double(workMinutes * 60)
        if let l = lunchSecs { return start.addingTimeInterval(work + l) }
        let ls = time(lunchStart, on: start), le = time(lunchEnd, on: start)
        let lunchAfterStart = max(0, le.timeIntervalSince(max(start, ls)))
        if start.addingTimeInterval(work) <= ls { return start.addingTimeInterval(work) }
        return start.addingTimeInterval(work + lunchAfterStart)
    }
}

/// "8 h" or "8 h 30 min".
func hoursText(_ minutes: Int) -> String {
    minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
}

enum Reminder: Equatable {
    case water, rest, lunch, windDown(minutesLeft: Int), dayDone, overtime(minutes: Int)
    case onLunch, backFromLunch(minutes: Int)
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
    /// You tapped "Going for lunch" and are not back yet. Work time stops.
    @Published var onLunch = false
    /// The Today strip shows "Going for lunch" until lunch is done for today.
    @Published var canGoLunch = false

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
    private var breakCounted = false
    private var snoozedUntil: Date?
    private var answeredAt: Date?
    private var day = ""

    // Saved per day, so a restart keeps the numbers.
    private func key(_ k: String) -> String { "coach.\(day).\(k)" }
    private var workSecs: Double { get { d.double(forKey: key("work")) } set { d.set(newValue, forKey: key("work")) } }
    private var waterAt: Double { get { d.double(forKey: key("waterAt")) } set { d.set(newValue, forKey: key("waterAt")) } }
    private var restAt: Double { get { d.double(forKey: key("restAt")) } set { d.set(newValue, forKey: key("restAt")) } }
    /// With autoStart: when today started, as seconds since 1970. 0 means not started yet.
    private var startedAt: Double { get { d.double(forKey: key("startedAt")) } set { d.set(newValue, forKey: key("startedAt")) } }
    /// "Going for lunch": when you left, as seconds since 1970. 0 means not on lunch.
    private var lunchOut: Double { get { d.double(forKey: key("lunchOut")) } set { d.set(newValue, forKey: key("lunchOut")) } }
    /// The real lunch so far today, in seconds. Used for the day's end once you went for lunch.
    private var lunchSecs: Double { get { d.double(forKey: key("lunchSecs")) } set { d.set(newValue, forKey: key("lunchSecs")) } }

    /// The lunch the day's end uses: nil (the lunch hours in Settings) until you go for lunch.
    /// While you are away it is never shorter than the lunch hours, so the end does not jump back.
    private func realLunch(_ c: DayConfig, now: Date) -> Double? {
        guard flag("lunchReal") else { return nil }
        guard lunchOut > 0 else { return lunchSecs }
        let planned = c.time(c.lunchEnd, on: now).timeIntervalSince(c.time(c.lunchStart, on: now))
        return max(lunchSecs + now.timeIntervalSince1970 - lunchOut, planned)
    }

    /// Today's start, end and time-check hour. Without autoStart they are the hours in Settings.
    /// With autoStart, the start is nil until your first input today, and so is the end.
    struct Hours { var start: Date?; var end: Date?; var checkFrom: Date? }
    func hours(_ c: DayConfig? = nil, on now: Date = Date()) -> Hours {
        let c = c ?? config
        guard c.autoStart else {
            return Hours(start: c.time(c.start, on: now), end: c.time(c.end, on: now), checkFrom: c.time(c.checkFrom, on: now))
        }
        guard Self.dayString(now) == day, startedAt > 0 else { return Hours() }
        let s = Date(timeIntervalSince1970: startedAt), e = c.autoEnd(from: s, lunchSecs: realLunch(c, now: now))
        return Hours(start: s, end: e, checkFrom: e.addingTimeInterval(Double(-autoCheckMinutes * 60)))
    }

    /// Settings: forget today's start, so your next input starts the day again. For a day that
    /// started too early, for example a quick look at the Mac before work.
    func restartToday(idle: Double? = nil, now: Date = Date()) {
        startedAt = -1   // not 0: the earlier first prompt in today's log must not come back
        for k in ["windDownSeen", "dayDoneSeen", "overtimeSeen"] { d.removeObject(forKey: key(k)) }
        reminder = nil
        tick(busy: false, idle: idle, now: now)
    }
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
        // A new length or lunch moves the end, so the end-of-day cards may need to come again.
        if c.autoStart != config.autoStart || c.workMinutes != config.workMinutes
            || c.start != config.start || c.end != config.end || c.checkFrom != config.checkFrom {
            for k in ["windDownSeen", "dayDoneSeen", "overtimeSeen"] { d.removeObject(forKey: key(k)) }
        }
        config = c
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: dayConfigURL)
        tick(busy: false)
    }

    /// `busy`: a Claude session is working for you (running, or asking you for under 10 minutes).
    /// `idle`: seconds since your last keyboard or mouse input. `ghosttyOpened`: when Ghostty
    /// started. `lastPromptAt`: tests pass it; the app reads your last prompt from today's log.
    func tick(busy: Bool, idle: Double? = nil, now: Date = Date(), ghosttyOpened: Date? = nil, lastPromptAt: Double? = nil) {
        let idle = idle ?? userIdleSeconds()
        let today = Self.dayString(now)
        if today != day { day = today; reminder = nil; snoozedUntil = nil; breakCounted = false; answeredAt = nil }
        let dt = lastTick.map { max(0, min(now.timeIntervalSince($0), 30)) } ?? 0   // the Mac may have slept
        lastTick = now

        let log = useLog ? readLog(today) : Log()
        // Seconds since your last prompt, typed here or sent from the phone.
        let sincePrompt = (lastPromptAt ?? log.lastPrompt).map { now.timeIntervalSince1970 - $0 } ?? .infinity

        // Lunch: back by the button, or by itself on the first input after 10 minutes away.
        if lunchOut > 0 && idle < 60 && now.timeIntervalSince1970 - idle >= lunchOut + lunchAutoBack {
            backFromLunch(now: now)
        }
        onLunch = lunchOut > 0

        let present = idle < activeWithin || sincePrompt < activeWithin
        let active = !onLunch && (present || busy)
        if active { workSecs += dt }
        if onLunch || idle < breakAfter || sincePrompt < breakAfter || busy {
            // Lunch resets the timers when you come back, so it is not counted as a break too.
            breakCounted = false
        } else if !breakCounted {
            // Ten minutes with no input, no prompt and nothing running: you stepped away. A break, once.
            breakCounted = true
            if workSecs - restAt > 60 {
                restAt = workSecs
                bump("breaks")
            }
        }

        let weekday = Calendar.current.component(.weekday, from: now)
        let workday = config.workdays.contains(weekday) && !dayOff
        if config.autoStart && workday && startedAt <= 0 && present
            && Calendar.current.component(.hour, from: now) >= earliestStartHour {
            // The day starts at your first use today: input or a prompt, not a running agent. If
            // the app opened late, an earlier prompt, new session or Ghostty start today is an
            // earlier start. After "Start again" (-1), only what you do now counts.
            let earliest = config.time("\(earliestStartHour):00", on: now).timeIntervalSince1970
            var s = max(earliest, now.timeIntervalSince1970 - min(idle, sincePrompt))
            if startedAt == 0 {
                for e in [log.firstPrompt, log.firstSession, ghosttyOpened?.timeIntervalSince1970] {
                    if let e, e >= earliest, e < s { s = e }
                }
            }
            startedAt = s
        }
        let h = hours(on: now)
        writeDayFile(h)
        canGoLunch = workday && !onLunch && !flag("lunchSeen") && h.start.map { now >= $0 } ?? !config.autoStart
        // Not started yet (autoStart): the day has no end, so it stays "before".
        let start = h.start ?? .distantFuture, end = h.end ?? .distantFuture, checkFrom = h.checkFrom ?? .distantFuture
        minutesLeft = h.end.map { max(0, Int($0.timeIntervalSince(now) / 60)) } ?? 0
        dayFraction = h.start == nil ? 0 : max(0, min(1, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
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
        // An automatic day that has not started: you are not at the Mac, so nothing to remind.
        if config.autoStart && phase == "before" { return nil }
        if onLunch { return .onLunch }
        if case .backFromLunch? = reminder { return reminder }
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
        case (.windDown, .windDown?), (.overtime, .overtime?), (.backFromLunch, .backFromLunch?): return true
        default: return a == b
        }
    }

    // MARK: - Buttons

    func done() {
        guard let r = reminder else { return }
        switch r {
        case .water: waterAt = workSecs; bump("water")
        // A rest or lunch includes a drink of water, so water starts again too. The water count stays.
        case .rest: restAt = workSecs; waterAt = workSecs; bump("breaks")
        case .lunch: setFlag("lunchSeen"); restAt = workSecs; waterAt = workSecs
        case .windDown: setFlag("windDownSeen")
        case .dayDone: setFlag("dayDoneSeen")
        case .overtime: bump("overtimeSeen")
        case .onLunch: backFromLunch(now: lastTick ?? Date()); return
        case .backFromLunch: break
        }
        reminder = nil
        answeredAt = lastTick ?? Date()
        tick(busy: false, now: lastTick ?? Date())
    }

    /// "Going for lunch": work time stops until you are back.
    func goLunch(now: Date = Date()) {
        guard lunchOut == 0 else { return }
        lunchOut = now.timeIntervalSince1970
        setFlag("lunchSeen")
        setFlag("lunchReal")
        snoozedUntil = nil
        reminder = .onLunch
        onLunch = true
        canGoLunch = false
    }

    /// Lunch ends: the real length is kept for the day's end, and rest and water start again.
    func backFromLunch(now: Date = Date()) {
        guard lunchOut > 0 else { return }
        let away = max(0, now.timeIntervalSince1970 - lunchOut)
        lunchSecs += away
        lunchOut = 0
        onLunch = false
        restAt = workSecs
        waterAt = workSecs
        breakCounted = true   // the same time away is not also a break
        reminder = .backFromLunch(minutes: Int(away / 60))
        if soundOn { NSSound(named: "Tink")?.play() }
    }

    func later() {
        snoozedUntil = Date().addingTimeInterval(600)
        reminder = nil
    }

    // MARK: - Today's log, written by stack-hook.sh

    struct Log { var prompts = 0, stops = 0, agents = 0; var firstPrompt: Double?, lastPrompt: Double?, firstSession: Double? }
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
            case "prompt":
                log.prompts += 1
                log.lastPrompt = o["t"] as? Double
                if log.firstPrompt == nil { log.firstPrompt = log.lastPrompt }
            case "session": if log.firstSession == nil { log.firstSession = o["t"] as? Double }
            case "stop": log.stops += 1
            case "agent": log.agents += 1
            default: break
            }
        }
        logCache = (day, mtime, log)
        return log
    }

    /// day-hook.sh cannot know an automatic day's hours, so they go in days/<date>.hours.json:
    /// {"start":"09:12","end":"17:57","checkFrom":"17:27","endMin":1077,"checkMin":1047}.
    /// The minutes count from today's midnight and can pass 1440 for a day that ends after it.
    /// No file means the day has not started, and the hook stays silent.
    private var writtenHours: (String, Double?, Double?)?
    private func writeDayFile(_ h: Hours) {
        guard useLog else { return }
        let url = daysDir.appendingPathComponent("\(day).hours.json")
        let sig = (day, h.start?.timeIntervalSince1970, h.end?.timeIntervalSince1970)
        if let w = writtenHours, w.0 == sig.0, w.1 == sig.1, w.2 == sig.2 { return }
        writtenHours = sig
        guard config.autoStart, let s = h.start, let e = h.end, let c = h.checkFrom else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let midnight = Calendar.current.startOfDay(for: s)
        let o: [String: Any] = ["start": f.string(from: s), "end": f.string(from: e), "checkFrom": f.string(from: c),
                                "endMin": Int(e.timeIntervalSince(midnight) / 60), "checkMin": Int(c.timeIntervalSince(midnight) / 60)]
        try? FileManager.default.createDirectory(at: daysDir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]).write(to: url, options: .atomic)
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
