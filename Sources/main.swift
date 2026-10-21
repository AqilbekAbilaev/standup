import AppKit
import ServiceManagement

// MARK: - Preferences

enum Prefs {
    private static let d = UserDefaults.standard

    static var workMinutes: Int {
        get { d.object(forKey: "workMinutes") as? Int ?? 45 }
        set { d.set(newValue, forKey: "workMinutes") }
    }

    static var breakMinutes: Int {
        get { d.object(forKey: "breakMinutes") as? Int ?? 5 }
        set { d.set(newValue, forKey: "breakMinutes") }
    }
}

// MARK: - Daily stats

enum Stat: String {
    case work       // seconds active at the computer (not on a break, not idle)
    case rest       // seconds on a break
    case idle       // seconds away from the keyboard outside of breaks
    case breaks     // breaks completed
    case skips      // breaks skipped with the emergency button
    case postpones  // "Postpone 5 minutes" clicks
}

/// Per-day counters stored as "<stat>-yyyy-MM-dd" in UserDefaults.
enum Stats {
    private static let d = UserDefaults.standard
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func key(_ stat: Stat, _ date: Date) -> String {
        stat.rawValue + "-" + dayFormat.string(from: date)
    }

    static func get(_ stat: Stat, on date: Date = Date()) -> Int {
        d.integer(forKey: key(stat, date))
    }

    static func add(_ stat: Stat, _ amount: Int = 1) {
        let k = key(stat, Date())
        d.set(d.integer(forKey: k) + amount, forKey: k)
    }
}

/// Seconds since the last keyboard/mouse input anywhere in the session.
func systemIdleSeconds() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

/// How long without input before the work countdown pauses.
let idleThreshold: TimeInterval = 2 * 60

func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = seconds % 3600 / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func formatClock(_ seconds: TimeInterval) -> String {
    let t = max(0, Int(seconds.rounded(.up)))
    return String(format: "%d:%02d", t / 60, t % 60)
}

let breakTips = [
    "Walk around the room, or go get a glass of water.",
    "Take a short walk — down the hall and back.",
    "Do 10 slow squats, then walk for a minute.",
    "Climb a flight of stairs if you can.",
    "Stretch your hips and lower back, then walk around.",
    "Look out the window at something far away while you walk.",
    "Refill your water bottle — staying hydrated helps too.",
]

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case working, onBreak, paused }

    private var state: State = .working
    private var workStarted = Date()
    private var workEnds = Date()
    /// Work time left, frozen while you're away from the keyboard or the Mac is asleep.
    private var idleRemaining: TimeInterval?
    private var breakEnds = Date()
    private var pausedUntil: Date?
    private var warned = false
    private var wasIdle = false

    private var statusItem: NSStatusItem!
    private let overlay = BreakOverlay()
    private let hud = WarningHUD()
    private let statsWindow = StatsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "StandUp")
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onDone = { [weak self] in self?.endBreak(taken: true) }
        overlay.onSkip = { [weak self] in self?.endBreak(taken: false) }

        // Sleep pauses the work countdown; the first tick after wake picks it back up.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.state == .working else { return }
            self.idleRemaining = self.idleRemaining ?? self.workEnds.timeIntervalSinceNow
        }

        startWork()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
    }

    // MARK: State transitions

    private func startWork(after minutes: Int = Prefs.workMinutes) {
        state = .working
        pausedUntil = nil
        warned = false
        idleRemaining = nil
        workStarted = Date()
        workEnds = Date().addingTimeInterval(TimeInterval(minutes * 60))
        updateTitle()
    }

    private func startBreak() {
        hud.hide()
        state = .onBreak
        breakEnds = Date().addingTimeInterval(TimeInterval(Prefs.breakMinutes * 60))
        overlay.show(remaining: breakEnds.timeIntervalSinceNow)
        updateTitle()
    }

    private func endBreak(taken: Bool) {
        overlay.hide()
        Stats.add(taken ? .breaks : .skips)
        startWork()
    }

    private func pause(minutes: Int?) {
        hud.hide()
        state = .paused
        pausedUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        updateTitle()
    }

    private func tick() {
        recordTime()
        statsWindow.refresh()

        switch state {
        case .working:
            let idle = systemIdleSeconds()
            if idleRemaining == nil && idle >= idleThreshold {
                // Stepped away: freeze the countdown, giving back the idle time already counted.
                let credit = min(idle, Date().timeIntervalSince(workStarted))
                idleRemaining = workEnds.timeIntervalSinceNow + credit
            }
            if let frozen = idleRemaining {
                workEnds = Date().addingTimeInterval(frozen)
                if idle >= idleThreshold { break }
                idleRemaining = nil // back at the keyboard: resume from where it stopped
            }
            let left = workEnds.timeIntervalSinceNow
            if left <= 60 && !warned {
                warned = true
                hud.show("Break in 1 minute — wrap up what you're doing")
            }
            if left <= 0 { startBreak() }
        case .onBreak:
            overlay.update(remaining: breakEnds.timeIntervalSinceNow)
            overlay.enforce()
        case .paused:
            if let until = pausedUntil, until <= Date() { startWork() }
        }
        updateTitle()
    }

    /// Adds this second to today's worked, rest or idle total.
    private func recordTime() {
        if state == .onBreak {
            Stats.add(.rest)
            return
        }
        let idle = systemIdleSeconds() >= idleThreshold
        if idle && !wasIdle {
            // The threshold's worth of seconds before idle was noticed were counted as work.
            Stats.add(.work, -Int(idleThreshold))
            Stats.add(.idle, Int(idleThreshold))
        }
        wasIdle = idle
        Stats.add(idle ? .idle : .work)
    }

    private func updateTitle() {
        let title: String
        switch state {
        case .working:
            let left = workEnds.timeIntervalSinceNow
            title = left < 60 ? formatClock(left) : "\(Int((left / 60).rounded(.up)))m"
        case .onBreak: title = "Break"
        case .paused: title = "Paused"
        }
        statusItem.button?.title = " " + title
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header: String
        switch state {
        case .working: header = "Next break in \(formatClock(workEnds.timeIntervalSinceNow))"
        case .onBreak: header = "On a break"
        case .paused:
            if let until = pausedUntil {
                let f = DateFormatter()
                f.timeStyle = .short
                header = "Paused until \(f.string(from: until))"
            } else {
                header = "Paused"
            }
        }
        menu.addItem(disabled(header))
        menu.addItem(disabled("Worked today: \(formatDuration(Stats.get(.work)))"))
        menu.addItem(disabled("Breaks taken today: \(Stats.get(.breaks))"))
        menu.addItem(item("Statistics…") { [weak self] in self?.statsWindow.show() })
        menu.addItem(.separator())

        if state == .working {
            menu.addItem(item("Take a break now") { [weak self] in self?.startBreak() })
            menu.addItem(item("Postpone 5 minutes") { [weak self] in
                guard let self else { return }
                Stats.add(.postpones)
                self.startWork(after: max(0, Int(self.workEnds.timeIntervalSinceNow / 60)) + 5)
            })
            menu.addItem(item("Pause for 1 hour") { [weak self] in self?.pause(minutes: 60) })
            menu.addItem(item("Pause until I resume") { [weak self] in self?.pause(minutes: nil) })
        } else if state == .paused {
            menu.addItem(item("Resume") { [weak self] in self?.startWork() })
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Work interval", options: [20, 25, 30, 45, 50, 60, 90],
                             current: Prefs.workMinutes) { [weak self] m in
            Prefs.workMinutes = m
            if self?.state == .working { self?.startWork() }
        })
        menu.addItem(submenu("Break length", options: [1, 2, 3, 5, 10, 15],
                             current: Prefs.breakMinutes) { m in
            Prefs.breakMinutes = m
        })

        let login = item("Launch at login") {
            let svc = SMAppService.mainApp
            do {
                if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't change login item"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit StandUp") { NSApp.terminate(nil) })
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, action: action)
    }

    private func submenu(_ title: String, options: [Int], current: Int,
                         _ pick: @escaping (Int) -> Void) -> NSMenuItem {
        let parent = NSMenuItem(title: "\(title): \(current) min", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in options {
            let i = item("\(m) min") { pick(m) }
            i.state = m == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// MARK: - Full-screen break overlay

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {} // swallow typing
}

final class BreakOverlay {
    var onDone: (() -> Void)?
    var onSkip: (() -> Void)?

    private var windows: [OverlayWindow] = []
    private var views: [BreakView] = []
    private var finished = false
    private var tip = ""
    private var remaining: TimeInterval = 0
    private var screenObserver: NSObjectProtocol?

    func show(remaining: TimeInterval) {
        finished = false
        tip = breakTips.randomElement()!
        self.remaining = remaining
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching,
                                     .disableHideApplication, .disableAppleMenu]
        buildWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.buildWindows() }
        NSSound(named: "Blow")?.play()
    }

    func update(remaining: TimeInterval) {
        self.remaining = remaining
        if remaining <= 0 && !finished {
            finished = true
            NSSound(named: "Glass")?.play()
        }
        views.forEach { $0.update(remaining: remaining, finished: finished) }
    }

    /// Keep the overlay in front if something tries to steal focus.
    func enforce() {
        guard !windows.isEmpty else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        windows.forEach { $0.orderFrontRegardless() }
        if !(windows.contains { $0.isKeyWindow }) { windows.first?.makeKey() }
    }

    func hide() {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        NSApp.presentationOptions = []
        NSApp.hide(nil) // hand focus back to whatever you were using
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        // Main screen first so it becomes the key window.
        let screens = NSScreen.screens.sorted { a, _ in a == NSScreen.main }
        for screen in screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false

            let v = BreakView(tip: tip)
            v.onDone = { [weak self] in self?.onDone?() }
            v.onSkip = { [weak self] in self?.onSkip?() }
            v.update(remaining: remaining, finished: finished)
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
            views.append(v)
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }
}

final class BreakView: NSVisualEffectView {
    var onDone: (() -> Void)?
    var onSkip: (() -> Void)?

    private let countdown = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "I'm back — start working", target: nil, action: nil)
    private let skipButton = HoldButton(label: "Hold 3s to skip (emergency)")

    init(tip: String) {
        super.init(frame: .zero)
        material = .fullScreenUI
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        let dim = NSView()
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 80, weight: .regular))
        icon.contentTintColor = .white

        let title = NSTextField(labelWithString: "Time to get up and move")
        title.font = .systemFont(ofSize: 44, weight: .semibold)
        title.textColor = .white

        let tipLabel = NSTextField(wrappingLabelWithString: tip)
        tipLabel.font = .systemFont(ofSize: 22)
        tipLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        tipLabel.alignment = .center

        countdown.font = .monospacedDigitSystemFont(ofSize: 120, weight: .light)
        countdown.textColor = .white

        subtitle.font = .systemFont(ofSize: 16)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.6)

        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large
        doneButton.keyEquivalent = "\r"
        doneButton.isHidden = true

        skipButton.onComplete = { [weak self] in self?.onSkip?() }

        let stack = NSStackView(views: [icon, title, tipLabel, countdown, subtitle, doneButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(40, after: tipLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        skipButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(skipButton)

        NSLayoutConstraint.activate([
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            tipLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            skipButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            skipButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(remaining: TimeInterval, finished: Bool) {
        countdown.stringValue = formatClock(remaining)
        subtitle.stringValue = finished ? "Nice. Welcome back." : "Screen unlocks when the timer ends"
        doneButton.isHidden = !finished
        skipButton.isHidden = finished
    }

    @objc private func done() { onDone?() }
}

/// A button that only fires after being held down for a few seconds,
/// so skipping a break takes deliberate effort.
final class HoldButton: NSView {
    var onComplete: (() -> Void)?

    private let label: String
    private let holdDuration: TimeInterval = 3
    private var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    private var timer: Timer?
    private var pressStart: Date?

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 34) }

    override func mouseDown(with event: NSEvent) {
        pressStart = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func mouseUp(with event: NSEvent) { cancel() }

    private func step() {
        guard let start = pressStart else { return }
        progress = min(1, CGFloat(Date().timeIntervalSince(start) / holdDuration))
        if progress >= 1 {
            cancel()
            onComplete?()
        }
    }

    private func cancel() {
        timer?.invalidate()
        timer = nil
        pressStart = nil
        progress = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.06).setFill()
        path.fill()

        if progress > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.white.withAlphaComponent(0.2).setStroke()
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

// MARK: - "Break in 1 minute" banner

final class WarningHUD {
    private var panel: NSPanel?

    func show(_ text: String) {
        hide()
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 420, height: 52)
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.maxY - size.height - 12,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])

        p.contentView = bg
        p.orderFrontRegardless()
        panel = p
        NSSound(named: "Tink")?.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak p] in
            if let self, self.panel === p { self.hide() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Stats window

final class StatsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "StandUp Statistics"
            w.isReleasedWhenClosed = false
            w.contentView = StatsView()
            w.center()
            window = w
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard let w = window, w.isVisible else { return }
        w.contentView?.needsDisplay = true
    }
}

final class StatsView: NSView {
    override var isFlipped: Bool { true }

    private let timeStats: [(Stat, String, NSColor)] = [
        (.work, "Worked", .controlAccentColor),
        (.rest, "Rest", .systemGreen),
        (.idle, "Idle", .systemGray),
    ]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let pad: CGFloat = 24, gap: CGFloat = 12, tileH: CGFloat = 84

        // Today's tiles: time split on the first row, counts on the second
        text("Today", x: pad, y: pad, size: 13, weight: .semibold, color: .secondaryLabelColor)
        let rows: [[(String, String, NSColor?)]] = [
            timeStats.map { (formatDuration(Stats.get($0.0)), $0.1, $0.2) },
            [("\(Stats.get(.breaks))", "Breaks taken", nil),
             ("\(Stats.get(.skips))", "Breaks skipped", nil),
             ("\(Stats.get(.postpones))", "Postponed", nil)],
        ]
        for (row, tiles) in rows.enumerated() {
            let tileW = (bounds.width - pad * 2 - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
            for (i, (value, label, color)) in tiles.enumerated() {
                let r = NSRect(x: pad + CGFloat(i) * (tileW + gap), y: pad + 24 + CGFloat(row) * (tileH + gap),
                               width: tileW, height: tileH)
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
                text(value, x: r.minX + 14, y: r.minY + 12, size: 28, weight: .semibold, color: .labelColor)
                var labelX = r.minX + 14
                if let color {
                    dot(color, x: labelX, y: r.minY + 59)
                    labelX += 14
                }
                text(label, x: labelX, y: r.minY + 54, size: 12, color: .secondaryLabelColor)
            }
        }

        // Last 7 days: stacked worked/rest/idle bars with break counts underneath
        let chartTop = pad + 24 + tileH * 2 + gap + 32
        text("Last 7 days", x: pad, y: chartTop, size: 13, weight: .semibold, color: .secondaryLabelColor)
        var legendX = bounds.width - pad
        for (_, label, color) in timeStats.reversed() {
            legendX -= attributed(label, size: 12, weight: .regular, color: .labelColor).size().width
            text(label, x: legendX, y: chartTop, size: 12, color: .secondaryLabelColor)
            legendX -= 14
            dot(color, x: legendX, y: chartTop + 5)
            legendX -= 16
        }

        let days = (0..<7).reversed().map { Calendar.current.date(byAdding: .day, value: -$0, to: Date())! }
        let values = days.map { day in timeStats.map { Stats.get($0.0, on: day) } }
        let maxTotal = max(values.map { $0.reduce(0, +) }.max() ?? 0, 3600)
        let plotTop = chartTop + 44, plotBottom = bounds.height - pad - 40
        let scale = (plotBottom - plotTop) / CGFloat(maxTotal)
        let slot = (bounds.width - pad * 2) / CGFloat(days.count)
        let barW = min(40, slot * 0.5)
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"

        for (i, day) in days.enumerated() {
            let isToday = i == days.count - 1
            let cx = pad + slot * (CGFloat(i) + 0.5)
            let total = values[i].reduce(0, +)
            let barH = max(2, CGFloat(total) * scale)
            let bar = NSRect(x: cx - barW / 2, y: plotBottom - barH, width: barW, height: barH)

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bar, xRadius: min(4, barH / 2), yRadius: min(4, barH / 2)).addClip()
            if total == 0 {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                bar.fill()
            }
            var y = plotBottom
            for (j, (_, _, color)) in timeStats.enumerated() {
                let h = CGFloat(values[i][j]) * scale
                color.withAlphaComponent(isToday ? 1 : 0.6).setFill()
                NSRect(x: bar.minX, y: y - h, width: barW, height: h).fill()
                y -= h
            }
            NSGraphicsContext.restoreGraphicsState()

            if values[i][0] > 0 {
                text(formatDuration(values[i][0]), centerX: cx, y: bar.minY - 18, size: 11, color: .secondaryLabelColor)
            }
            text(isToday ? "Today" : weekday.string(from: day), centerX: cx, y: plotBottom + 8,
                 size: 12, color: .labelColor)
            let b = Stats.get(.breaks, on: day)
            text("\(b) break\(b == 1 ? "" : "s")", centerX: cx, y: plotBottom + 24,
                 size: 11, color: .secondaryLabelColor)
        }
    }

    private func dot(_ color: NSColor, x: CGFloat, y: CGFloat) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 8, height: 8)).fill()
    }

    private func attributed(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }

    private func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular, color: NSColor) {
        attributed(s, size: size, weight: weight, color: color).draw(at: NSPoint(x: x, y: y))
    }

    private func text(_ s: String, centerX: CGFloat, y: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular, color: NSColor) {
        let a = attributed(s, size: size, weight: weight, color: color)
        a.draw(at: NSPoint(x: centerX - a.size().width / 2, y: y))
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
