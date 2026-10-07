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

enum Edge: Int { case left, right, bottom, bottomLeft, bottomRight }

/// An invisible strip on the window edge. Drag it to resize.
struct ResizeHandle: View {
    let edge: Edge
    let onResize: (Edge, Bool) -> Void
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    switch edge {
                    case .left, .right: NSCursor.resizeLeftRight.push()
                    case .bottom: NSCursor.resizeUpDown.push()
                    default: NSCursor.crosshair.push()
                    }
                } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in onResize(edge, true) }
                .onEnded { _ in onResize(edge, false) })
    }
}

struct StackView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Prefs
    @ObservedObject var reader: ReaderModel
    let web: ReaderWebView
    let focuser: Focuser
    let onDrag: (DragGesture.Value?) -> Void
    let onResize: (Edge, Bool) -> Void
    let onResetPosition: () -> Void
    var onZoom: () -> Void = {}

    var body: some View {
        if prefs.reader && !prefs.compact { readerBody } else { stackBody }
    }

    // MARK: Small stack

    var stackBody: some View {
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
                ForEach(store.rows) { r in
                    RowView(row: r, now: store.now, t: t, onTap: { focuser.focus(r.s) },
                            onExpand: { reader.select(r.id); prefs.reader = true })
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
                iconButton("arrow.up.left.and.arrow.down.right", "Open the reader") { prefs.reader = true }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { prefs.compact.toggle() }
        .help("Drag to move. Double-click to shrink or grow.")
    }

    func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(muted)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(surface))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Reader

    var readerBody: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                readerHeader(t: tl.date.timeIntervalSinceReferenceDate)
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { onDrag($0) }
                .onEnded { _ in onDrag(nil) })
            .contextMenu { menu }
            Rectangle().fill(borderC).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                        VStack(spacing: 6) {
                            ForEach(store.rows) { r in
                                RowView(row: r, now: store.now, t: tl.date.timeIntervalSinceReferenceDate,
                                        selected: r.id == reader.selectedId, onTap: { reader.select(r.id) })
                            }
                        }
                        .padding(8)
                    }
                }
                .frame(width: 290)
                .contextMenu { menu }
                Rectangle().fill(borderC).frame(width: 1)
                ReaderPane(web: web)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderC, lineWidth: 1))
        .overlay(alignment: .trailing) { ResizeHandle(edge: .right, onResize: onResize).frame(width: 6).padding(.vertical, 14) }
        .overlay(alignment: .leading) { ResizeHandle(edge: .left, onResize: onResize).frame(width: 6).padding(.vertical, 14) }
        .overlay(alignment: .bottom) { ResizeHandle(edge: .bottom, onResize: onResize).frame(height: 6).padding(.horizontal, 14) }
        .overlay(alignment: .bottomTrailing) { ResizeHandle(edge: .bottomRight, onResize: onResize).frame(width: 16, height: 16) }
        .overlay(alignment: .bottomLeading) { ResizeHandle(edge: .bottomLeft, onResize: onResize).frame(width: 16, height: 16) }
    }

    func readerHeader(t: Double) -> some View {
        let needCount = store.rows.filter { $0.display == .needs }.count
        return HStack(spacing: 8) {
            WindowButtons(onClose: { prefs.reader = false }, onMinimize: { prefs.reader = false }, onZoom: onZoom)
                .padding(.trailing, 6)
            Image(systemName: "square.stack.3d.up.fill").foregroundColor(Color(hex: 0xFF9A00))
            Text("Claude Stack").font(.system(size: 13, weight: .bold)).foregroundColor(textC)
            Spacer()
            if needCount > 0 {
                Text("\(needCount) need\(needCount == 1 ? "s" : "") you")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Display.needs.color.opacity(0.4 + 0.6 * wave(t, hz: 1.6)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onZoom)
        .help("Drag to move. Double-click to fill the screen. Drag an edge or a bottom corner to resize.")
    }

    @ViewBuilder var menu: some View {
        Toggle("Sound when a tab needs you", isOn: $prefs.soundOnNeeds)
        Toggle("Mac banner when a tab needs you", isOn: $prefs.bannerOnNeeds)
        Toggle("Sound when a task is done", isOn: $prefs.soundOnDone)
        Divider()
        Toggle("Reader", isOn: $prefs.reader)
        Toggle("Compact (pill)", isOn: $prefs.compact)
        Button("Reset position and size", action: onResetPosition)
        Divider()
        Button("Quit Claude Stack") { NSApp.terminate(nil) }
    }
}

/// The red, yellow and green buttons, as on every Mac window. Symbols show on hover.
struct WindowButtons: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            dot(0xFF5F57, "xmark", "Close the reader (the small stack stays)", onClose)
            dot(0xFEBC2E, "minus", "Shrink to the small stack", onMinimize)
            dot(0x28C840, "arrow.up.left.and.arrow.down.right", "Fill the screen, or go back to the old size", onZoom)
        }
        .onHover { hover = $0 }
    }

    func dot(_ hex: UInt32, _ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(hex: hex)).frame(width: 13, height: 13)
                Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5).frame(width: 13, height: 13)
                if hover {
                    Image(systemName: icon).font(.system(size: 7, weight: .heavy)).foregroundColor(Color.black.opacity(0.6))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
