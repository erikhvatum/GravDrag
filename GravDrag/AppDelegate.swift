import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var simViewController: SimulationViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        simViewController = SimulationViewController()

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "GravDrag"
        window.contentViewController = simViewController
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.minSize = NSSize(width: 640, height: 480)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About GravDrag", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit GravDrag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Select All", action: #selector(SimulationViewController.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Delete Selected", action: #selector(SimulationViewController.deleteSelected(_:)), keyEquivalent: "\u{7F}")

        // Simulation menu
        let simItem = NSMenuItem(title: "Simulation", action: nil, keyEquivalent: "")
        mainMenu.addItem(simItem)
        let simMenu = NSMenu(title: "Simulation")
        simItem.submenu = simMenu
        simMenu.addItem(withTitle: "Play / Pause", action: #selector(SimulationViewController.togglePause(_:)), keyEquivalent: " ")
        simMenu.addItem(withTitle: "Reset", action: #selector(SimulationViewController.resetSimulation(_:)), keyEquivalent: "r")

        NSApplication.shared.mainMenu = mainMenu
    }
}
