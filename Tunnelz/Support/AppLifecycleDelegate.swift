import AppKit

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var processManager: TunnelProcessManager?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Handle tunnelz:// links here instead of letting SwiftUI open a new window for them.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.processManager?.shutdownForApplicationTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: value) else {
            return
        }
        MainActor.assumeIsolated { handleRelayLink(url) }
    }

    @MainActor
    private func handleRelayLink(_ url: URL) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()

        guard let link = RelayManager.parseConnectLink(url) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Invalid Relay Link"
            alert.informativeText = "This link is incomplete. Ask your admin for a new one."
            alert.runModal()
            return
        }

        // A link can overwrite the current relay, so always ask first and say what changes.
        let currentDomain = UserDefaults.standard.string(forKey: RelayManager.domainKey) ?? ""
        let replacesRelay = !currentDomain.isEmpty && currentDomain != link.domain
        let alert = NSAlert()
        if replacesRelay {
            alert.alertStyle = .critical
            alert.messageText = "Replace \(currentDomain) with \(link.domain)?"
            alert.informativeText = "All relay tunnels on this Mac will go through \(link.domain), which can see their traffic. Only continue if the link came from your admin."
        } else {
            alert.messageText = "Connect to \(link.domain)?"
            alert.informativeText = "Tunnelz will send relay tunnel traffic through this server. Only continue if the link came from your admin."
        }
        alert.addButton(withTitle: replacesRelay ? "Replace" : "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let defaults = UserDefaults.standard
        defaults.set(link.domain, forKey: RelayManager.domainKey)
        defaults.set(link.token, forKey: RelayManager.accountTokenKey)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        Task { @MainActor in
            let relay = RelayManager()
            await relay.checkInstallation()
            do {
                if relay.status == .missing {
                    await relay.install()
                }
                try await relay.connect(domain: link.domain, accountToken: link.token)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not connect to \(link.domain)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isApplicationWindow(window) else {
            return
        }

        DispatchQueue.main.async {
            let hasVisibleApplicationWindow = NSApplication.shared.windows.contains {
                self.isApplicationWindow($0) && $0.isVisible
            }
            if !hasVisibleApplicationWindow {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    private func isApplicationWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }
}
