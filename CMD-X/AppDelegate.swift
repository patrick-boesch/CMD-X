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
    private var setupWindow: NSWindow?
    private var setupStatus: NSTextField?
    private let setupItem = NSMenuItem(title: "Einrichtung und Status …", action: #selector(showSetup), keyEquivalent: "")
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
        statusItem.button?.image = indicatorImage(active: false, busy: false)
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
        cancelItem.isEnabled = false
        errorItem.isHidden = true
        for item in [setupItem, cancelItem, errorItem, permissionItem, loginItem] {
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
        NSLog("[CMD-X] running app=%@", Bundle.main.bundleURL.path)
        NSLog("[CMD-X] accessibility trusted=%@", String(AXIsProcessTrusted()))
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
        if !controller.isEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.controller.isEnabled else { return }
                self.showSetup()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The setup window also remains reachable if macOS hides status items for lack of space.
        showSetup()
        return false
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
        else if !controller.isEnabled { title = controller.accessMessage }
        else if active { title = "\(controller.items.count) Element(e) ausgeschnitten" }
        else { title = "Bereit – nichts ausgeschnitten" }
        statusLine.title = title
        statusItem.button?.toolTip = "CMD-X: \(title)"
        statusItem.button?.setAccessibilityLabel("CMD-X: \(title)")
        statusItem.button?.image = indicatorImage(active: active, busy: busy)
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
        setupStatus?.stringValue = controller.accessMessage
        cancelItem.isEnabled = active && !busy
        permissionItem.isHidden = controller.accessState != .needsAccessibility
        errorItem.isHidden = lastError == nil
        quitItem.isEnabled = !controller.isMoving
    }

    @objc private func cancelCut() { controller.cancel() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func enableAccessibility() {
        // One route only: do not stack the AX system alert on top of our own UI.
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

    private func indicatorImage(active: Bool, busy: Bool) -> NSImage {
        // Explicit size and drawing remove dependence on SF Symbol rendering.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
            circle.lineWidth = 1.8
            if active || busy {
                (busy ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
                circle.fill()
            } else {
                NSColor.black.setStroke()
                circle.stroke()
            }
            return true
        }
        // Let macOS supply a legible monochrome color for the idle ring.
        image.isTemplate = !active && !busy
        return image
    }

    @objc private func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 350),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CMD-X – Einrichtung"
            window.isReleasedWhenClosed = false
            let heading = NSTextField(labelWithString: "Ausschneiden im Finder")
            heading.font = .boldSystemFont(ofSize: 18)
            let status = NSTextField(wrappingLabelWithString: "Tastaturzugriff wird geprüft …")
            status.font = .boldSystemFont(ofSize: 13)
            setupStatus = status
            let explanation = NSTextField(wrappingLabelWithString:
                "Ist CMD-X bereits aktiviert, kann der Eintrag zu einem älteren Build gehören. Entferne den bisherigen CMD-X-Eintrag unter Bedienungshilfen und füge über + genau die unten gezeigte App erneut hinzu. Starte CMD-X danach neu.")
            let path = NSTextField(wrappingLabelWithString: Bundle.main.bundleURL.path)
            path.isSelectable = true
            path.textColor = .secondaryLabelColor
            let privacy = NSButton(title: "Bedienungshilfen öffnen", target: self, action: #selector(enableAccessibility))
            let reveal = NSButton(title: "Diese App im Finder zeigen", target: self, action: #selector(revealRunningApp))
            let retry = NSButton(title: "Erneut prüfen", target: self, action: #selector(recheckAccess))
            let buttons = NSStackView(views: [privacy, reveal])
            buttons.spacing = 8
            let note = NSTextField(wrappingLabelWithString:
                "Die separate Finder-Steuerung wird erst beim ersten Einfügen angefragt. Der Kreis ist bei einer vorgemerkten Auswahl farbig gefüllt.")
            note.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [heading, status, explanation, path, buttons, retry, note])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = window.contentView!
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor),
                explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
                path.widthAnchor.constraint(equalTo: stack.widthAnchor),
                note.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
            stack.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 530, height: max(350, stack.fittingSize.height + 48)))
            window.center()
            setupWindow = window
        }
        setupStatus?.stringValue = didStartServices ? controller.accessMessage : "CMD-X startet …"
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func recheckAccess() {
        guard didStartServices else { return }
        if !AXIsProcessTrusted() { controller.stop() }
        controller.start()
        refresh()
    }
}
