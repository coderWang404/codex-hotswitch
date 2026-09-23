// Codex 热切换 — 桌面 App（主窗口 + 菜单栏图标）
// 不重启 Codex 应用，直接热切换 cc-switch 的第三方模型供应商。
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let windowController = MainWindowController()
    private let backend = Backend.shared
    private lazy var watcher = ConfigWatcher(configPath: configPath)
    private var providers: [ProviderSummary] = []
    private var currentId: String?
    private var menuStatus: String?

    private var configPath: String {
        NSString(string: "~/.codex/config.toml").expandingTildeInPath
    }

    private var defaults: UserDefaults { .standard }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            forName: .configWrittenFromApp, object: nil, queue: .main
        ) { [weak self] _ in
            // 自身写入的配置不应触发自动跟随
            self?.watcher.baselineNow()
        }

        NotificationCenter.default.addObserver(
            forName: .watchToggled, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.defaults.bool(forKey: "watchEnabled") {
                self.startWatching()
            } else {
                self.watcher.stop()
            }
        }

        windowController.show { [weak self] providers, currentId in
            self?.providers = providers
            self?.currentId = currentId
            self?.updateStatusTitle()
        }

        if defaults.bool(forKey: "watchEnabled") { startWatching() }
        windowController.setWatchState(watcher.isRunning)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.show { [weak self] providers, currentId in
            self?.providers = providers
            self?.currentId = currentId
            self?.updateStatusTitle()
        }
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Codex 热切换", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "环境自检…", action: #selector(showDoctor), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: "打开 config.toml", action: #selector(openConfig), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Codex 热切换", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Codex 热切换", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: 菜单栏图标（菜单栏有空间时显示；空间不足时系统会隐藏，不影响主窗口使用）

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill",
                                     accessibilityDescription: "Codex 热切换")
        item.button?.toolTip = "Codex 热切换（单击查看供应商）"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let showName = defaults.object(forKey: "showNameInMenuBar") as? Bool ?? false
        if showName, let provider = providers.first(where: { $0.id == currentId }) {
            let name = provider.name.count > 10 ? String(provider.name.prefix(10)) + "…" : provider.name
            button.title = " \(name)"
            statusItem?.length = NSStatusItem.variableLength
        } else {
            button.title = ""
            statusItem?.length = NSStatusItem.squareLength
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let menuStatus {
            let status = NSMenuItem(title: menuStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())

        let openWindow = NSMenuItem(title: "打开主窗口", action: #selector(showWindow), keyEquivalent: "")
        openWindow.target = self
        menu.addItem(openWindow)

        addUtilityItems(menu)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Codex 热切换", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addUtilityItems(_ menu: NSMenu) {
        let reload = NSMenuItem(title: "重新加载 Codex", action: #selector(reloadNow), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let watch = NSMenuItem(title: "自动跟随切换", action: #selector(toggleWatchFromMenu), keyEquivalent: "")
        watch.target = self
        watch.state = watcher.isRunning ? .on : .off
        menu.addItem(watch)

        let nameItem = NSMenuItem(title: "菜单栏显示供应商名称", action: #selector(toggleShowName), keyEquivalent: "")
        nameItem.target = self
        nameItem.state = (defaults.object(forKey: "showNameInMenuBar") as? Bool ?? false) ? .on : .off
        menu.addItem(nameItem)

        menu.addItem(.separator())
        let doctor = NSMenuItem(title: "环境自检…", action: #selector(showDoctor), keyEquivalent: "")
        doctor.target = self
        menu.addItem(doctor)
    }

    private func headerText() -> String {
        if let provider = providers.first(where: { $0.id == currentId }) {
            return "当前: \(provider.name) · \(provider.model ?? "-")"
        }
        return "当前: (未知)"
    }

    // MARK: 操作

    @objc private func showWindow() {
        windowController.show { [weak self] providers, currentId in
            self?.providers = providers
            self?.currentId = currentId
            self?.updateStatusTitle()
        }
    }

    @objc private func reloadNow() {
        menuStatus = "正在重新加载 Codex…"
        let scope = defaults.string(forKey: "scope") ?? "chatgpt"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let remote = self.defaults.object(forKey: "syncRemote") as? Bool ?? true
                let result = try self.backend.reload(scope: scope, remote: remote)
                let remoteText = result.remote?.hosts.map { host in
                    host.ok ? (host.changed ? "\(host.label) 已同步" : "\(host.label) 已一致") : "\(host.label) 失败"
                }.joined(separator: "、") ?? ""
                DispatchQueue.main.async {
                    let suffix = remoteText.isEmpty ? "" : " · 远程 \(remoteText)"
                    self.menuStatus = "✔ 已重新加载\(suffix)"
                    self.windowController.setStatus("✔ 已重新加载 Codex\(suffix)")
                }
            } catch {
                DispatchQueue.main.async { self.menuStatus = "❌ \(error.localizedDescription)" }
            }
        }
    }

    @objc private func toggleWatchFromMenu() {
        if watcher.isRunning {
            watcher.stop()
            defaults.set(false, forKey: "watchEnabled")
            menuStatus = "已关闭自动跟随"
        } else {
            startWatching()
            menuStatus = "已开启自动跟随"
        }
        windowController.setWatchState(watcher.isRunning)
    }

    @objc private func toggleShowName() {
        let current = defaults.object(forKey: "showNameInMenuBar") as? Bool ?? false
        defaults.set(!current, forKey: "showNameInMenuBar")
        updateStatusTitle()
    }

    private func startWatching() {
        watcher.onChanged = { [weak self] in
            guard let self else { return }
            self.menuStatus = "检测到配置变化，正在热重启…"
            self.windowController.autoReloadAfterChange { [weak self] in
                guard let self else { return }
                self.menuStatus = "⚡ 已自动跟随切换"
                self.windowController.refresh()
            }
        }
        watcher.start()
        defaults.set(true, forKey: "watchEnabled")
        menuStatus = "已开启自动跟随"
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Codex 热切换"
        alert.informativeText = """
        不重启 Codex 应用，热切换 cc-switch 管理的第三方模型供应商。

        · 原理：切换配置后只重启 Codex 的 app-server 子进程
        · 自动跟随：在 cc-switch 里切换后自动生效
        · 远程同步：内置机器和自己添加的 SSH 机器一起跟上本机供应商
        · 工具目录：\(backend.scriptPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? "未找到")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showDoctor() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let message: String
            do {
                let result = try self.backend.doctor()
                message = result.checks.map { "\($0.ok ? "✅" : "❌") \($0.label)" }.joined(separator: "\n")
            } catch {
                message = "自检失败: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "环境自检"
                alert.informativeText = message
                alert.alertStyle = .informational
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}
