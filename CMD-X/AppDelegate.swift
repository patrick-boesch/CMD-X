import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Clipboard access must not precede installation of the status item.
    private lazy var controller = ShortcutController()
    private var didStartServices = false
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cancelItem = NSMenuItem(title: "Ausschneiden aufheben", action: #selector(cancelCut), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Bedienungshilfen erlauben …", action: #selector(enableAccessibility), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Beim Anmelden starten", action: #selector(toggleLogin), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "CMD-X beenden", action: #selector(quit), keyEquivalent: "q")
    private var permissionTimer: Timer?
    private var lastError: String?
    private let errorItem = NSMenuItem(title: "Letzten Hinweis anzeigen …", action: #selector(showLastError), keyEquivalent: "")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSLog("[CMD-X] applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[CMD-X] applicationDidFinishLaunching")
        // Avoid two instances competing for the same shortcuts; log why we exit.
        if let identifier = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            if !others.isEmpty {
                let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
                NSLog("[CMD-X] another instance is running (PID %@); exiting this instance", pids)
                NSApp.terminate(nil)
                return
            }
        }
        NSLog("[CMD-X] installing status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A visible fallback is present before symbols, permissions or services load.
        statusItem.button?.title = "○"
        statusItem.button?.toolTip = "CMD-X startet …"
        statusItem.isVisible = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        let help = NSMenuItem(title: "Finder: ⌘X ausschneiden · ⌘V verschieben", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        menu.addItem(.separator())
        for item in [cancelItem, errorItem, permissionItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        NSLog("[CMD-X] status item installed; isVisible=%@", String(statusItem.isVisible))
        // Return from the launch callback before calling services or showing modals.
        DispatchQueue.main.async { [weak self] in self?.startServices() }
    }

    private func startServices() {
        guard !didStartServices else { return }
        NSLog("[CMD-X] initializing clipboard controller")
        _ = controller
        didStartServices = true
        NSLog("[CMD-X] clipboard controller initialized")
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onError = { [weak self] message in
            self?.lastError = message
            self?.refresh()
            self?.showLastError()
        }
        NSLog("[CMD-X] starting keyboard access")
        controller.start()
        refresh()
        NSLog("[CMD-X] keyboard setup returned; enabled=%@", String(controller.isEnabled))
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted() { self.controller.stop() }
            if !self.controller.isEnabled { self.controller.start() }
            self.refresh()
        }
        permissionTimer?.tolerance = 0.5
        NSLog("[CMD-X] startup complete")
        if !AXIsProcessTrusted() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !AXIsProcessTrusted() else { return }
                NSLog("[CMD-X] showing accessibility setup")
                self.showWelcome()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[CMD-X] applicationWillTerminate")
        if didStartServices { controller.stop() }
        permissionTimer?.invalidate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didStartServices && controller.isMoving {
            lastError = "Finder verschiebt noch Dateien. Bitte den laufenden Vorgang zuerst im Finder abschließen."
            showLastError()
            return .terminateCancel
        }
        return .terminateNow
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard didStartServices else { return }
        refresh()
        // Login-item status may involve XPC; it is not required for startup/rendering.
        NSLog("[CMD-X] checking login-item status")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func refresh() {
        guard statusItem != nil, didStartServices else { return }
        let active = !controller.items.isEmpty
        let busy = controller.isMoving || controller.isCapturing
        let title: String
        if controller.isMoving { title = "Dateien werden verschoben …" }
        else if controller.isCapturing { title = "Auswahl wird übernommen …" }
        else if !controller.isEnabled { title = "Bedienungshilfen-Zugriff erforderlich" }
        else if active { title = "\(controller.items.count) Element(e) ausgeschnitten" }
        else { title = "Bereit – nichts ausgeschnitten" }
        statusLine.title = title
        statusItem.button?.toolTip = "CMD-X: \(title)"
        statusItem.button?.setAccessibilityLabel("CMD-X: \(title)")
        let symbol = busy ? "circle.dotted" : (active ? "circle.fill" : "circle")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? (active ? "●" : "○") : ""
        statusItem.button?.contentTintColor = busy ? .systemOrange : (active ? .controlAccentColor : .secondaryLabelColor)
        cancelItem.isEnabled = active && !busy
        permissionItem.isHidden = controller.isEnabled
        errorItem.isHidden = lastError == nil
        quitItem.isEnabled = !controller.isMoving
    }

    @objc private func cancelCut() { controller.cancel() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func enableAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            lastError = "Autostart konnte nicht geändert werden: \(error.localizedDescription)"
            showLastError()
        }
        refresh()
    }

    @objc private func showLastError() {
        guard let lastError else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "CMD-X"
        alert.informativeText = String(lastError.prefix(1600))
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ausschneiden für den Finder"
        alert.informativeText = "CMD-X ergänzt ⌘X und ⌘V für Dateien und Ordner. Erlaube zunächst den Bedienungshilfen-Zugriff. Beim ersten Verschieben fragt macOS zusätzlich nach der Finder-Steuerung.\n\nDer Kreis in der Menüleiste wird farbig, sobald Dateien ausgeschnitten sind."
        alert.addButton(withTitle: "Bedienungshilfen öffnen")
        alert.addButton(withTitle: "Später")
        if alert.runModal() == .alertFirstButtonReturn { enableAccessibility() }
    }
}
