// The SwiftUI views: the small stack (as before) and the reader mode around the web view.
import AppKit
import SwiftUI

let bg = Color(hex: 0x0F1923)
let surface = Color(hex: 0x1C2B3A)
let borderC = Color(hex: 0x2E3F50)
let textC = Color(hex: 0xF0F4F8)
let muted = Color(hex: 0x8A9BAE)

/// 0...1 wave for blinking and pulsing.
func wave(_ t: Double, hz: Double) -> Double { 0.5 + 0.5 * cos(t * 2 * .pi * hz) }

struct RowView: View {
    let row: Row
    let now: Double
    let t: Double
    var selected = false
    let onTap: () -> Void
    var onExpand: (() -> Void)? = nil
    @State private var hover = false

    var subtitle: String {
        if let p = row.s.prompt, !p.isEmpty { return p }
        return row.display == .ready ? "Waiting for your first message" : (row.s.cwd ?? "")
    }

    var body: some View {
        let c = row.display.color
        let needs = row.display == .needs
        let blink = needs ? wave(t, hz: 1.6) : 1
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(c.opacity(needs ? 0.25 + 0.35 * blink : 0.18)).frame(width: 26, height: 26)
                Image(systemName: row.display.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(c)
                    .opacity(row.display == .running ? 0.45 + 0.55 * wave(t, hz: 0.6) : 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundColor(textC).lineLimit(1).layoutPriority(1)
                    if row.background {
                        Text("BG").font(.system(size: 9, weight: .bold)).foregroundColor(muted)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(muted, lineWidth: 1))
                    }
                    if let b = row.s.branch, !b.isEmpty {
                        Text(b).font(.system(size: 10, design: .monospaced)).foregroundColor(muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 6) {
                    if row.agents > 0 {
                        Text("\(row.agents) agent\(row.agents == 1 ? "" : "s")")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(Display.running.color)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Display.running.color.opacity(0.15)))
                            .help("Subagents working right now")
                    }
                    Text(subtitle)
                        .font(.system(size: 11)).foregroundColor(muted).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            if hover, let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "text.bubble.fill").font(.system(size: 13)).foregroundColor(textC)
                }
                .buttonStyle(.plain)
                .help("Read this chat")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.detail).font(.system(size: 11, weight: .bold)).foregroundColor(c)
                Text(ago(now - row.since)).font(.system(size: 10, design: .monospaced)).foregroundColor(muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(needs ? c.opacity(0.10 + 0.16 * blink)
                      : selected ? Color(hex: 0x243447) : (hover ? surface.opacity(1) : surface.opacity(0.6)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(needs ? c.opacity(0.4 + 0.6 * blink) : (selected ? Color(hex: 0x427BBF) : Color.clear), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .help(onExpand == nil ? "Click to read this chat" : "Click to open this tab")
    }
}

struct StackView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Prefs
    @ObservedObject var reader: ReaderModel
    @ObservedObject var coach: DayCoach
    let focuser: Focuser
    let onDrag: (DragGesture.Value?) -> Void
    let onResetPosition: () -> Void
    /// Opens the reader window, on this session if one is given.
    var onOpenReader: (String?) -> Void = { _ in }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            content(t: tl.date.timeIntervalSinceReferenceDate)
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { onDrag($0) }
            .onEnded { _ in onDrag(nil) })
        .contextMenu { menu }
    }

    func content(t: Double) -> some View {
        let needCount = store.rows.filter { $0.display == .needs }.count
        let strokeColor: Color = needCount > 0
            ? Display.needs.color.opacity(0.35 + 0.65 * wave(t, hz: 1.6))
            : borderC
        let lineWidth: CGFloat = needCount > 0 ? 2 : 1
        return VStack(alignment: .leading, spacing: 6) {
            header(needCount: needCount, t: t)
            if !prefs.compact {
                if coach.phase != "off" { DayStrip(coach: coach, compact: true) }
                ReminderCard(coach: coach)
                ForEach(store.rows) { r in
                    RowView(row: r, now: store.now, t: t, onTap: { focuser.focus(r.s) },
                            onExpand: { onOpenReader(r.id) })
                }
            }
        }
        .padding(8)
        .frame(width: prefs.compact ? nil : 320, alignment: .leading)
        .fixedSize(horizontal: prefs.compact, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12).fill(bg.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(strokeColor, lineWidth: lineWidth))
    }

    func header(needCount: Int, t: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").foregroundColor(Color(hex: 0xFF9A00))
            Text("Claude").font(.system(size: 12, weight: .bold)).foregroundColor(textC)
            if prefs.compact {
                ForEach([Display.needs, .running, .stuck, .done, .ready, .idle], id: \.rawValue) { d in
                    let n = store.rows.filter { $0.display == d }.count
                    if n > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: d.icon).font(.system(size: 10, weight: .bold)).foregroundColor(d.color)
                                .opacity(d == .needs ? 0.3 + 0.7 * wave(t, hz: 1.6) : 1)
                            Text("\(n)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(d.color)
                        }
                    }
                }
            } else {
                Spacer()
                if needCount > 0 {
                    Text("\(needCount) need\(needCount == 1 ? "s" : "") you")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Display.needs.color)
                } else {
                    Text("\(store.rows.count) session\(store.rows.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundColor(muted)
                }
                Button { onOpenReader(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .bold)).foregroundColor(muted)
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(surface))
                }
                .buttonStyle(.plain)
                .help("Open the reader")
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { prefs.compact.toggle() }
        .help("Drag to move. Double-click to shrink or grow.")
    }

    @ViewBuilder var menu: some View {
        Toggle("Sound when a tab needs you", isOn: $prefs.soundOnNeeds)
        Toggle("Mac banner when a tab needs you", isOn: $prefs.bannerOnNeeds)
        Toggle("Sound when a task is done", isOn: $prefs.soundOnDone)
        Divider()
        Button("Open reader") { onOpenReader(nil) }
        Toggle("Compact (pill)", isOn: $prefs.compact)
        Button("Reset position", action: onResetPosition)
        Divider()
        Button("Quit Claude Stack") { NSApp.terminate(nil) }
    }
}

/// The reader window's content: sessions on the left, the chat page on the right.
/// It lives in a normal Mac window, so the title bar, its three buttons and resizing are the system's.
struct ReaderView: View {
    @ObservedObject var store: Store
    @ObservedObject var reader: ReaderModel
    @ObservedObject var coach: DayCoach
    @ObservedObject var prefs: Prefs
    let web: ReaderWebView
    var onKeepOnTop: () -> Void = {}
    @State private var tab = "chats"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Chats").tag("chats")
                    Text("Settings").tag("settings")
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 8).padding(.top, 8)
                DayStrip(coach: coach).padding(.horizontal, 8)
                ReminderCard(coach: coach).padding(.horizontal, 8)
                ScrollView {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                        VStack(spacing: 6) {
                            ForEach(store.rows) { r in
                                RowView(row: r, now: store.now, t: tl.date.timeIntervalSinceReferenceDate,
                                        selected: r.id == reader.selectedId,
                                        onTap: { reader.select(r.id); tab = "chats" })
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
            }
            .frame(width: 300)
            .animation(.easeInOut(duration: 0.3), value: coach.reminder)
            Rectangle().fill(borderC).frame(width: 1)
            // The web view stays alive under Settings, so the chat does not reload.
            ZStack {
                ReaderPane(web: web).opacity(tab == "chats" ? 1 : 0)
                if tab == "settings" { SettingsView(coach: coach, prefs: prefs, onKeepOnTop: onKeepOnTop) }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .background(bg)
    }
}
