import AppKit
import AVFoundation
import UniformTypeIdentifiers

// Window, controls and on-screen display.

final class VideoView: NSView {
    weak var controller: PlayerController?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if controller?.handleKey(e) != true { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.toggleFullScreen(nil); return }
        controller?.handleClick(at: convert(e.locationInWindow, from: nil), in: bounds)
    }
    override func mouseMoved(with e: NSEvent) { controller?.showOSD() }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}

final class PlayerController: NSObject, NSWindowDelegate {
    let player: Player
    let window: NSWindow
    private let view = VideoView()
    private let osd = CATextLayer()
    private let barBack = CALayer()
    private let barFill = CALayer()
    private let subLayer = CATextLayer()
    private var shownSub: String?
    private var subScale: CGFloat = 1
    private var osdUntil = Date()
    private var message: String?
    private var timer: Timer?
    private let resumeKey: String

    init(path: String) throws {
        player = try Player(path: path)
        resumeKey = "resume:" + path
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = (path as NSString).lastPathComponent
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        view.controller = self
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer!.backgroundColor = .black
        player.layer.frame = view.bounds
        player.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer!.addSublayer(player.layer)

        barBack.backgroundColor = CGColor(gray: 1, alpha: 0.25)
        barFill.backgroundColor = CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)
        barBack.cornerRadius = 3; barFill.cornerRadius = 3
        osd.fontSize = 20
        osd.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        osd.foregroundColor = .white
        osd.shadowOpacity = 1; osd.shadowRadius = 3; osd.shadowOffset = .zero
        osd.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        subLayer.isWrapped = true
        subLayer.alignmentMode = .center
        subLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        subLayer.shadowOpacity = 0.9; subLayer.shadowRadius = 4; subLayer.shadowOffset = .zero
        subLayer.shadowColor = .black
        view.layer!.addSublayer(subLayer)
        for l in [barBack, barFill, osd] { view.layer!.addSublayer(l) }

        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        player.onError = { [weak self] m in self?.flash(m) }
        let resume = UserDefaults.standard.double(forKey: resumeKey)
        player.play(from: resume > 30 && resume < player.duration - 60 ? resume - 3 : 0)
        flash("Bitstreaming to \(player.out.deviceLabel)  ·  right-click or Audio menu to change track")

        let savedScale = UserDefaults.standard.double(forKey: "subScale")
        if savedScale > 0 { subScale = CGFloat(savedScale) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private var lastSave = Date()
    private func tick() {
        player.syncTick()
        layoutOSD()
        layoutSubtitle()
        if Date().timeIntervalSince(lastSave) > 5 {
            UserDefaults.standard.set(player.position, forKey: resumeKey)
            lastSave = Date()
        }
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    func showOSD() { osdUntil = max(osdUntil, Date().addingTimeInterval(2.5)); NSCursor.unhide() }

    func flash(_ m: String) { message = m; osdUntil = Date().addingTimeInterval(4); }

    private func layoutOSD() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let visible = player.paused || Date() < osdUntil
        let b = view.bounds
        let pos = player.position
        let frac = player.duration > 0 ? pos / player.duration : 0
        barBack.frame = CGRect(x: 30, y: 30, width: b.width - 60, height: 6)
        barFill.frame = CGRect(x: 30, y: 30, width: (b.width - 60) * frac, height: 6)
        var text = "\(player.paused ? "❚❚" : "▶")  \(fmt(pos)) / \(fmt(player.duration))    🔊 \(trackTitle(player.audioTrack))  ·  \(modeText)"
        if let m = message, Date() < osdUntil { text += "\n" + m } else { message = nil }
        osd.string = text
        osd.frame = CGRect(x: 30, y: 44, width: b.width - 60, height: 60)
        for l in [barBack, barFill, osd] { l.opacity = visible ? 1 : 0 }
        CATransaction.commit()
        if !visible && window.styleMask.contains(.fullScreen) { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func subtitleText() -> NSAttributedString? {
        guard player.subtitleIndex != nil, let cue = player.subtitles.cue(at: player.position) else { return nil }
        let size = max(16, view.bounds.height * 0.045 * subScale)
        var font = NSFont.systemFont(ofSize: size, weight: .semibold)
        if cue.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        return NSAttributedString(string: cue.text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
            .strokeColor: NSColor.black, .strokeWidth: -2.5,
        ])
    }

    private func layoutSubtitle() {
        let text = subtitleText()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let text else {
            if shownSub != nil { subLayer.string = nil; shownSub = nil }
            return
        }
        let b = view.bounds
        let width = b.width * 0.86
        let h = ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 8
        let lifted = player.paused || Date() < osdUntil
        subLayer.frame = CGRect(x: (b.width - width) / 2, y: (lifted ? 110 : 0) + b.height * 0.05, width: width, height: h)
        let key = text.string + "\(text.size().height)"
        if key != shownSub {
            subLayer.string = text
            shownSub = key
            if ProcessInfo.processInfo.environment["ATMOS_DEBUG"] != nil {
                print(String(format: "[sub %.2f] %@", player.position, text.string.replacingOccurrences(of: "\n", with: " / ")))
                fflush(stdout)
            }
        }
    }

    // MARK: Subtitle menu

    func subtitleTitle(_ t: MKVTrack) -> String {
        let lang = Locale.current.localizedString(forLanguageCode: t.language) ?? t.language
        return t.name.isEmpty ? lang : "\(lang) — \(t.name)"
    }

    func fillSubtitleMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let off = NSMenuItem(title: "Off", action: #selector(pickSubtitle(_:)), keyEquivalent: "")
        off.target = self
        off.tag = -1
        off.state = player.subtitleIndex == nil ? .on : .off
        menu.addItem(off)
        for (i, t) in player.subtitleTracks.enumerated() {
            let item = NSMenuItem(title: subtitleTitle(t), action: #selector(pickSubtitle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = player.subtitleIndex == i ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, key, sel) in [("Next Subtitle", "s", #selector(nextSubtitle)),
                                  ("Bigger Subtitles", "=", #selector(biggerSubs)),
                                  ("Smaller Subtitles", "-", #selector(smallerSubs))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            item.target = self
            menu.addItem(item)
        }
    }

    func applySubtitle(_ i: Int?, announce: Bool = true) {
        player.selectSubtitle(i)
        let t = i.map { player.subtitleTracks[$0] }
        UserDefaults.standard.set(t?.language ?? "", forKey: "subLang")
        UserDefaults.standard.set(t?.name ?? "", forKey: "subName")
        if announce { flash("Subtitles: " + (t.map(subtitleTitle) ?? "Off")) }
        showOSD()
    }

    /// Re-selects the subtitle language chosen last time, if this file has it.
    func restoreSubtitle() {
        let lang = UserDefaults.standard.string(forKey: "subLang") ?? ""
        guard !lang.isEmpty else { return }
        let name = UserDefaults.standard.string(forKey: "subName") ?? ""
        let tracks = player.subtitleTracks
        if let i = tracks.firstIndex(where: { $0.language == lang && $0.name == name }) ?? tracks.firstIndex(where: { $0.language == lang }) {
            player.selectSubtitle(i)
        }
    }

    @objc func pickSubtitle(_ sender: NSMenuItem) { applySubtitle(sender.tag < 0 ? nil : sender.tag) }

    @objc func nextSubtitle() {
        let n = player.subtitleTracks.count
        guard n > 0 else { flash("This file has no text subtitles"); return }
        let next: Int? = player.subtitleIndex.map { $0 + 1 < n ? $0 + 1 : nil } ?? 0
        applySubtitle(next)
    }

    @objc func biggerSubs() { setSubScale(subScale + 0.1) }
    @objc func smallerSubs() { setSubScale(subScale - 0.1) }

    private func setSubScale(_ v: CGFloat) {
        subScale = min(2.5, max(0.5, v))
        UserDefaults.standard.set(Double(subScale), forKey: "subScale")
        shownSub = nil
        flash("Subtitle size \(Int((subScale * 100).rounded()))%")
        showOSD()
    }

    func handleClick(at p: NSPoint, in b: NSRect) {
        if p.y < 60 && p.x >= 30 && p.x <= b.width - 30 {
            player.seek(to: Double((p.x - 30) / (b.width - 60)) * player.duration)
        } else {
            player.togglePause()
        }
        showOSD()
    }

    func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 49: player.togglePause()                         // space
        case 123: player.seek(by: -10)                        // left
        case 124: player.seek(by: 10)                         // right
        case 125: player.seek(by: -60)                        // down
        case 126: player.seek(by: 60)                         // up
        case 53: if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } // esc
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "f": window.toggleFullScreen(nil)
            case "a": nextTrack()
            case "r": cycleBoost()
            case "s": nextSubtitle()
            case "=", "+": biggerSubs()
            case "-": smallerSubs()
            case let c? where c.count == 1 && "123456789".contains(c):
                let i = Int(c)! - 1
                guard i < player.audioTracks.count else { return false }
                player.selectAudioTrack(i)
                flash("Audio: " + trackTitle(player.audioTrack))
            case "[":
                player.soundDelay -= 0.01
                flash(String(format: "Picture delay %+.0f ms (press ] if lips move before the sound)", player.soundDelay * 1000))
            case "]":
                player.soundDelay += 0.01
                flash(String(format: "Picture delay %+.0f ms (press [ if the sound comes first)", player.soundDelay * 1000))
            case "q": NSApp.terminate(nil)
            default: return false
            }
        }
        showOSD()
        return true
    }

    // MARK: Audio track menu

    func trackTitle(_ t: MKVTrack) -> String {
        let lang = Locale.current.localizedString(forLanguageCode: t.language) ?? t.language
        let atmos = t.name.localizedCaseInsensitiveContains("atmos")
        let name = t.name.isEmpty ? "Track \(t.number)" : t.name
        return "\(lang) — \(name)\(atmos ? "  ◆ Dolby Atmos" : "")"
    }

    func fillAudioMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (i, t) in player.audioTracks.enumerated() {
            let item = NSMenuItem(title: trackTitle(t), action: #selector(pickTrack(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.tag = i
            item.state = i == player.audioIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let next = NSMenuItem(title: "Next Audio Track", action: #selector(nextTrack), keyEquivalent: "a")
        next.keyEquivalentModifierMask = []
        next.target = self
        menu.addItem(next)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Rear Speakers", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for db in PlayerController.boostSteps {
            let title = db == 0 ? "Normal — true Dolby Atmos" : "Rear Boost +\(Int(db)) dB  (5.1, no height)"
            let item = NSMenuItem(title: title, action: #selector(pickBoost(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(db)
            item.state = player.rearBoostDB == db ? .on : .off
            menu.addItem(item)
        }
        let cycle = NSMenuItem(title: "Next Rear Level", action: #selector(cycleBoost), keyEquivalent: "r")
        cycle.keyEquivalentModifierMask = []
        cycle.target = self
        menu.addItem(cycle)
    }

    static let boostSteps: [Double] = [0, 3, 6, 9, 12]

    var modeText: String {
        player.rearBoostDB == 0 ? "Dolby Atmos" : "Rear Boost +\(Int(player.rearBoostDB)) dB"
    }

    func applyBoost(_ db: Double) {
        do {
            try player.setRearBoost(db)
            UserDefaults.standard.set(db, forKey: "rearBoost")
            flash(db == 0 ? "Rear speakers: normal — sending true Dolby Atmos"
                          : "Rear Boost +\(Int(db)) dB — Mac decodes to 5.1 (Atmos height off)")
        } catch {
            flash("Couldn't switch audio mode: \(error)")
        }
        showOSD()
    }

    @objc func pickBoost(_ sender: NSMenuItem) { applyBoost(Double(sender.tag)) }

    @objc func cycleBoost() {
        let steps = PlayerController.boostSteps
        let i = steps.firstIndex(of: player.rearBoostDB) ?? 0
        applyBoost(steps[(i + 1) % steps.count])
    }

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        let header = NSMenuItem(title: "Audio Track", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        let sub = NSMenu()
        fillAudioMenu(sub)
        for item in sub.items { sub.removeItem(item); m.addItem(item) }
        m.addItem(.separator())
        let subHeader = NSMenuItem(title: "Subtitles", action: nil, keyEquivalent: "")
        subHeader.isEnabled = false
        m.addItem(subHeader)
        let subMenu = NSMenu()
        fillSubtitleMenu(subMenu)
        let subItem = NSMenuItem(title: "Subtitles: " + (player.subtitleIndex.map { subtitleTitle(player.subtitleTracks[$0]) } ?? "Off"),
                                 action: nil, keyEquivalent: "")
        subItem.submenu = subMenu
        m.addItem(subItem)
        m.addItem(.separator())
        let pause = NSMenuItem(title: player.paused ? "Play" : "Pause", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        m.addItem(pause)
        let fs = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        m.addItem(fs)
        return m
    }

    @objc func pickTrack(_ sender: NSMenuItem) {
        player.selectAudioTrack(sender.tag)
        flash("Audio: " + trackTitle(player.audioTrack))
        showOSD()
    }

    @objc func nextTrack() {
        flash("Audio: " + trackTitle(player.cycleAudioTrack()))
        showOSD()
    }

    @objc func togglePause() { player.togglePause(); showOSD() }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func shutdown() {
        UserDefaults.standard.set(player.position, forKey: resumeKey)
        UserDefaults.standard.set(player.soundDelay, forKey: "soundDelay")
        timer?.invalidate()
        player.shutdown()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controller: PlayerController?
    var pendingPath: String?
    private var currentPath: String?
    private var launched = false
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                         reason: "Playing video")
        installSignalRestore()
        launched = true
        if let p = pendingPath { open(p) }
        else if CommandLine.arguments.count > 1, FileManager.default.fileExists(atPath: CommandLine.arguments[1]) {
            open(CommandLine.arguments[1])
        } else {
            DispatchQueue.main.async { self.showOpenPanel() }
        }
    }

    func application(_ app: NSApplication, openFile filename: String) -> Bool {
        if !launched { pendingPath = filename; return true }
        open(filename)
        return true
    }

    func open(_ path: String) {
        // macOS also delivers launch arguments as open-file requests; ignore repeats.
        if path == currentPath && controller != nil { return }
        currentPath = path
        controller?.shutdown()
        controller?.window.delegate = nil
        controller?.window.close()
        controller = nil
        do {
            let c = try PlayerController(path: path)
            let saved = UserDefaults.standard.object(forKey: "soundDelay") as? Double
            if let saved { c.player.soundDelay = saved }
            c.restoreSubtitle()
            let boost = UserDefaults.standard.double(forKey: "rearBoost")
            if boost > 0 { c.applyBoost(boost) }
            controller = c
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let a = NSAlert()
            a.messageText = "Can't play this file"
            a.informativeText = "\(error)"
            a.runModal()
            if controller == nil { NSApp.terminate(nil) }
        }
    }

    @objc func showOpenPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "mkv") ?? .movie]
        p.message = "Choose an MKV with Dolby Digital Plus / Atmos audio"
        if p.runModal() == .OK, let u = p.url { open(u.path) }
        else if controller == nil { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ n: Notification) { controller?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    private func installSignalRestore() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.controller?.shutdown(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Atmos Player", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Atmos Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(showOpenPanel), keyEquivalent: "o").target = self
        fileItem.submenu = fileMenu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        let audioItem = NSMenuItem()
        main.addItem(audioItem)
        let audioMenu = NSMenu(title: "Audio")
        audioMenu.delegate = self
        audioItem.submenu = audioMenu
        let subsItem = NSMenuItem()
        main.addItem(subsItem)
        let subsMenu = NSMenu(title: "Subtitles")
        subsMenu.delegate = self
        subsItem.submenu = subsMenu
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Audio" {
            if let c = controller { c.fillAudioMenu(menu) } else { menu.removeAllItems() }
        }
        if menu.title == "Subtitles" {
            if let c = controller { c.fillSubtitleMenu(menu) } else { menu.removeAllItems() }
        }
    }
}

func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
