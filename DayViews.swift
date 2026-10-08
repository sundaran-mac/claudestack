// Day coach views: the day strip, the reminder card with calm animations, and the Settings tab.
import AppKit
import SwiftUI

let calmBlue = Color(hex: 0x5B9BE6)
let calmGreen = Color(hex: 0x06C27A)
let calmAmber = Color(hex: 0xF4A500)
let water = Color(hex: 0x4FC3F7)

/// Day progress plus the water and rest gauges.
struct DayStrip: View {
    @ObservedObject var coach: DayCoach
    var compact = false

    var barColor: Color {
        switch coach.phase {
        case "windDown": return calmAmber
        case "done": return calmGreen
        default: return calmBlue
        }
    }

    var label: String {
        switch coach.phase {
        case "off": return "Day off · \(hm(coach.summary.workSecs)) worked"
        case "before": return "Day starts at \(coach.config.start)"
        case "done": return "Day complete · \(hm(coach.summary.workSecs)) worked"
        default: return "\(hm(coach.summary.workSecs)) worked · \(hm(Double(coach.minutesLeft * 60))) left"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: compact ? 10.5 : 11.5, weight: .semibold)).foregroundColor(textC).lineLimit(1)
                Spacer(minLength: 4)
                Gauge(icon: "drop.fill", color: water, value: coach.waterFraction, help: "Water: fills up to the next reminder")
                Gauge(icon: "figure.walk", color: calmGreen, value: coach.restFraction, help: "Rest: fills up to the next break")
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(surface)
                    Capsule().fill(barColor).frame(width: max(4, g.size.width * coach.dayFraction))
                        .animation(.easeInOut(duration: 0.6), value: coach.dayFraction)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 5 : 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(surface.opacity(compact ? 0.5 : 0.7)))
        .help("Your day \(coach.config.start) to \(coach.config.end)")
    }
}

/// A small ring that fills up toward the next reminder.
struct Gauge: View {
    let icon: String
    let color: Color
    let value: Double
    let help: String
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, value)).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: value)
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundColor(color)
        }
        .frame(width: 20, height: 20)
        .help(help)
    }
}

/// The one reminder that is due now. Calm colours and slow motion: orange blinking stays for "Claude needs you".
struct ReminderCard: View {
    @ObservedObject var coach: DayCoach

    var body: some View {
        if let r = coach.reminder {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                card(r, t: tl.date.timeIntervalSinceReferenceDate)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    func card(_ r: Reminder, t: Double) -> some View {
        let c = color(r)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                art(r, t: t).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(r)).font(.system(size: 13.5, weight: .bold)).foregroundColor(textC)
                    Text(body(r)).font(.system(size: 11.5)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if r == .dayDone { summaryGrid }
            HStack(spacing: 8) {
                Button(doneLabel(r)) { withAnimation { coach.done() } }
                    .buttonStyle(CoachButton(color: c, filled: true))
                if r != .dayDone {
                    Button("10 min later") { withAnimation { coach.later() } }
                        .buttonStyle(CoachButton(color: c, filled: false))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(c.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(c.opacity(0.35 + 0.25 * wave(t, hz: 0.25)), lineWidth: 1.2))
    }

    var summaryGrid: some View {
        let s = coach.summary
        let cells: [(String, String)] = [("Worked", hm(s.workSecs)), ("Prompts", "\(s.prompts)"), ("Tasks done", "\(s.tasksDone)"),
                                         ("Agents", "\(s.agents)"), ("Water", "\(s.water)"), ("Breaks", "\(s.breaks)")]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(cells, id: \.0) { cell in
                VStack(spacing: 1) {
                    Text(cell.1).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(textC)
                    Text(cell.0).font(.system(size: 9.5, weight: .semibold)).foregroundColor(muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(surface))
            }
        }
    }

    // MARK: Words

    func title(_ r: Reminder) -> String {
        switch r {
        case .water: return "Time for water"
        case .rest: return "Time to rest"
        case .lunch: return "Lunch time"
        case .windDown(let m): return "\(m) minutes left today"
        case .dayDone: return "Day complete. Well done."
        case .overtime(let m): return "\(m) minutes past your day"
        }
    }

    func body(_ r: Reminder) -> String {
        switch r {
        case .water: return "You worked \(coach.config.waterMinutes) minutes. Drink a glass of water."
        case .rest: return "Two hours without a break. Stand up, walk, and look away from the screen for 5 minutes."
        case .lunch: return "Step away until \(coach.config.lunchEnd). Claude can wait."
        case .windDown: return "Finish what you have. New tasks now get a time check from Claude before they start."
        case .dayDone: return "Here is today. Save your work and stop for the day."
        case .overtime: return "Save your work and leave the rest for tomorrow."
        }
    }

    func doneLabel(_ r: Reminder) -> String {
        switch r {
        case .water: return "I drank water"
        case .rest: return "I took a break"
        case .lunch: return "Back from lunch"
        case .windDown, .overtime: return "OK"
        case .dayDone: return "Close for today"
        }
    }

    func color(_ r: Reminder) -> Color {
        switch r {
        case .water: return water
        case .rest, .lunch, .dayDone: return calmGreen
        case .windDown, .overtime: return calmAmber
        }
    }

    // MARK: Animations

    @ViewBuilder func art(_ r: Reminder, t: Double) -> some View {
        switch r {
        case .water:
            // A drop that fills and settles with a slow wave.
            ZStack {
                Image(systemName: "drop.fill").resizable().scaledToFit().foregroundColor(water.opacity(0.18))
                WaveFill(level: 0.55 + 0.08 * sin(t * 1.4), phase: t * 2.2)
                    .fill(water)
                    .mask(Image(systemName: "drop.fill").resizable().scaledToFit())
            }
        case .rest, .lunch:
            // A breathing circle: four seconds in, four seconds out.
            let b = 0.5 + 0.5 * sin(t * .pi / 4)
            ZStack {
                Circle().fill(calmGreen.opacity(0.12 + 0.12 * b)).scaleEffect(0.7 + 0.3 * b)
                Image(systemName: r == .lunch ? "fork.knife" : "figure.walk").font(.system(size: 17, weight: .semibold)).foregroundColor(calmGreen)
            }
        case .windDown(let m):
            ZStack {
                Circle().stroke(calmAmber.opacity(0.2), lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat(min(1, Double(m) / 30)))
                    .stroke(calmAmber, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(m)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(calmAmber)
            }
        case .dayDone:
            // A ring that draws itself, then a soft glow.
            let p = min(1, (t.truncatingRemainder(dividingBy: 6)) / 1.2)
            ZStack {
                Circle().fill(calmGreen.opacity(0.10 + 0.08 * wave(t, hz: 0.3)))
                Circle().trim(from: 0, to: p).stroke(calmGreen, style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.system(size: 16, weight: .heavy)).foregroundColor(calmGreen).opacity(p)
            }
        case .overtime:
            Image(systemName: "moon.stars.fill").font(.system(size: 22)).foregroundColor(calmAmber)
                .opacity(0.7 + 0.3 * wave(t, hz: 0.25))
        }
    }
}

/// The water surface inside the drop.
struct WaveFill: Shape {
    var level: Double
    var phase: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = r.maxY - r.height * level
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for i in stride(from: 0, through: 40, by: 1) {
            let x = r.minX + r.width * Double(i) / 40
            p.addLine(to: CGPoint(x: x, y: y0 + 2.5 * sin(Double(i) / 40 * 2 * .pi + phase)))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct CoachButton: ButtonStyle {
    let color: Color
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundColor(filled ? Color(hex: 0x0F1923) : color)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(filled ? color : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: filled ? 0 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var coach: DayCoach
    @ObservedObject var prefs: Prefs
    var onKeepOnTop: () -> Void = {}
    @State private var c = DayConfig.load()
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.system(size: 22, weight: .bold)).foregroundColor(textC)

                section("Your day", "Work time, reminders and the evening time check use these hours.") {
                    timeRow("Day starts", $c.start)
                    timeRow("Day ends", $c.end)
                    timeRow("Time check for new tasks from", $c.checkFrom,
                            note: "After this time, Claude checks if a new task fits before the day ends, and asks you first if it does not.")
                    timeRow("Lunch starts", $c.lunchStart)
                    timeRow("Lunch ends", $c.lunchEnd)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Workdays").font(.system(size: 12.5, weight: .semibold)).foregroundColor(textC)
                        HStack(spacing: 6) {
                            ForEach([(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")], id: \.0) { d in
                                let on = c.workdays.contains(d.0)
                                Button(d.1) {
                                    if on { c.workdays.removeAll { $0 == d.0 } } else { c.workdays.append(d.0) }
                                }
                                .buttonStyle(CoachButton(color: calmBlue, filled: on))
                            }
                        }
                    }
                }

                section("Reminders", "Counted in work time: while you use the keyboard or mouse. Five minutes with no input is a break.") {
                    stepRow("Water every", $c.waterMinutes, range: 15...180, step: 15)
                    stepRow("Rest after", $c.restMinutes, range: 30...240, step: 15,
                            note: "Five minutes away from the keyboard and mouse count as a break and start this again.")
                    Toggle("Soft sound when a reminder comes", isOn: Binding(get: { coach.soundOn }, set: { coach.soundOn = $0; UserDefaults.standard.set($0, forKey: "coachSound") }))
                    Toggle("Day off today (no reminders, no time check)", isOn: Binding(get: { coach.dayOff }, set: { coach.dayOff = $0 }))
                }

                HStack(spacing: 10) {
                    Button(saved ? "Saved" : "Save day settings") {
                        coach.save(c)
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                    }
                    .buttonStyle(CoachButton(color: calmGreen, filled: true))
                    Button("Undo changes") { c = coach.config }
                        .buttonStyle(CoachButton(color: muted, filled: false))
                }

                section("Claude alerts", "When a tab needs you or finishes.") {
                    Toggle("Sound when a tab needs you", isOn: $prefs.soundOnNeeds)
                    Toggle("Mac banner when a tab needs you", isOn: $prefs.bannerOnNeeds)
                    Toggle("Sound when a task is done", isOn: $prefs.soundOnDone)
                }

                section("Window", "") {
                    Toggle("Keep the reader on top of all apps", isOn: Binding(get: { prefs.keepOnTop }, set: { _ in onKeepOnTop() }))
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .toggleStyle(.switch)
            .controlSize(.mini)   // the small switches macOS uses in its own settings
            .tint(calmBlue)
        }
        .scrollIndicators(.never)   // .hidden loses to "Always show scroll bars" in System Settings
        .background(bg)
        .onAppear { c = coach.config }
    }

    func section<Content: View>(_ title: String, _ note: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(textC)
            if !note.isEmpty { Text(note).font(.system(size: 11.5)).foregroundColor(muted) }
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(surface))
                .foregroundColor(textC)
                .font(.system(size: 12.5))
        }
    }

    func timeRow(_ label: String, _ value: Binding<String>, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                DatePicker("", selection: Binding(
                    get: { c.time(value.wrappedValue, on: Date()) },
                    set: { value.wrappedValue = timeString($0) }), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.stepperField)
                    .controlSize(.regular)   // bigger than the mini switches, so the time is easy to read
            }
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(muted) }
        }
    }

    func stepRow(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>, step: Int, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Stepper("\(value.wrappedValue) min", value: value, in: range, step: step)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .controlSize(.large)   // bigger than the mini switches, so the arrows are easy to click
            }
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(muted) }
        }
    }

    func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
