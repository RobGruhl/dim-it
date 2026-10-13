// DimIt — menu bar toggle between a "Day" and a "Night" brightness preset
// across every attached Apple display (built-in, Studio Display, XDR).
//
// Left-click the icon: toggle Day <-> Night.
// Right-click (or ctrl-click): menu with presets, "save current as…", login item, quit.

import AppKit
import ServiceManagement

// MARK: - DisplayServices (private framework; how Control Center's slider talks to Apple panels)

private let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
private let dsGet = unsafeBitCast(dlsym(ds, "DisplayServicesGetBrightness"), to: GetBrightnessFn.self)
private let dsSet = unsafeBitCast(dlsym(ds, "DisplayServicesSetBrightness"), to: SetBrightnessFn.self)

struct Display {
    let id: CGDirectDisplayID
    let key: String  // stable across reboots/replugs

    static func online() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).compactMap { id in
            var b: Float = 0
            guard dsGet(id, &b) == 0 else { return nil }  // skip displays we can't drive
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let key = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "id-\(id)"
            return Display(id: id, key: key)
        }
    }

    var isBuiltin: Bool { CGDisplayIsBuiltin(id) != 0 }

    var brightness: Float {
        get { var b: Float = 0; _ = dsGet(id, &b); return b }
        nonmutating set { _ = dsSet(id, max(0, min(1, newValue))) }
    }
}

// MARK: - Presets (per-display levels, stored in UserDefaults)

enum Mode: String { case day, night }

struct Presets {
    static let defaults = UserDefaults.standard
    // Night: externals go darker, the laptop stays a bit brighter.
    static func fallback(_ mode: Mode, for d: Display) -> Float {
        switch mode {
        case .day: return 0.7
        case .night: return d.isBuiltin ? 0.12 : 0.04
        }
    }

    static func level(_ mode: Mode, for d: Display) -> Float {
        let stored = defaults.dictionary(forKey: mode.rawValue) as? [String: Float]
        return stored?[d.key] ?? fallback(mode, for: d)
    }

    static func saveCurrent(as mode: Mode) {
        var stored = defaults.dictionary(forKey: mode.rawValue) as? [String: Float] ?? [:]
        for d in Display.online() { stored[d.key] = d.brightness }
        defaults.set(stored, forKey: mode.rawValue)
    }

    static var isSeeded: Bool { defaults.dictionary(forKey: Mode.day.rawValue) != nil }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var fadeTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // First run: whatever the sliders are at now is "Day".
        if !Presets.isSeeded { Presets.saveCurrent(as: .day) }

        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon()
    }

    /// Whichever preset the displays are currently closest to.
    private var currentMode: Mode {
        var dDay: Float = 0, dNight: Float = 0
        for d in Display.online() {
            let b = d.brightness
            dDay += abs(b - Presets.level(.day, for: d))
            dNight += abs(b - Presets.level(.night, for: d))
        }
        return dNight < dDay ? .night : .day
    }

    private func refreshIcon(_ mode: Mode? = nil) {
        let m = mode ?? currentMode
        let symbol = m == .night ? "moon.fill" : "sun.max.fill"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: m == .night ? "Night" : "Day")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = "DimIt — \(m == .night ? "Night" : "Day") (click to toggle, right-click for menu)"
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            apply(currentMode == .night ? .day : .night)
        }
    }

    private func apply(_ mode: Mode) {
        fadeTimer?.invalidate()
        let displays = Display.online()
        let start = displays.map { $0.brightness }
        let end = displays.map { Presets.level(mode, for: $0) }
        let steps = 15
        var i = 0
        refreshIcon(mode)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.25 / Double(steps), repeats: true) { [weak self] t in
            i += 1
            let f = Float(i) / Float(steps)
            for (n, d) in displays.enumerated() { d.brightness = start[n] + (end[n] - start[n]) * f }
            if i >= steps { t.invalidate(); self?.fadeTimer = nil }
        }
    }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()
        let mode = currentMode
        let day = menu.addItem(withTitle: "Day", action: #selector(goDay), keyEquivalent: "")
        day.state = mode == .day ? .on : .off
        let night = menu.addItem(withTitle: "Night", action: #selector(goNight), keyEquivalent: "")
        night.state = mode == .night ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save Current Brightness as Day", action: #selector(saveDay), keyEquivalent: "")
        menu.addItem(withTitle: "Save Current Brightness as Night", action: #selector(saveNight), keyEquivalent: "")
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit DimIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for mi in menu.items where mi.action != #selector(NSApplication.terminate(_:)) { mi.target = self }

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil  // so left-click goes back to toggling
    }

    @objc private func goDay() { apply(.day) }
    @objc private func goNight() { apply(.night) }
    @objc private func saveDay() { Presets.saveCurrent(as: .day); refreshIcon() }
    @objc private func saveNight() { Presets.saveCurrent(as: .night); refreshIcon() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
