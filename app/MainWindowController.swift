// 主窗口：供应商列表 + 一键热切换 + 自动跟随。
import AppKit
import ServiceManagement

final class MainWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var headerLabel: NSTextField!
    private var effectiveLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var reloadButton: NSButton!
    private var watchSwitch: NSSwitch!
    private var scopePopup: NSPopUpButton!
    private var focusSwitch: NSSwitch!
    private var remoteSwitch: NSSwitch!
    private var loginSwitch: NSSwitch!
    private var spinner: NSProgressIndicator!
    private var remoteRows: NSStackView!
    private var addRemoteButton: NSButton!
    private let remotes = RemoteStore.shared

    private let backend = Backend.shared
    private var providers: [ProviderSummary] = []
    private var currentId: String?
    private var liveInfo: LiveInfo?
    private var remoteLive: [String: RemoteHostInfo] = [:]
    private var ccSwitchRunning = false
    private var busy = false
    private var onProvidersChanged: (([ProviderSummary], String?) -> Void)?

    private var defaults: UserDefaults { .standard }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(onProvidersChanged: @escaping ([ProviderSummary], String?) -> Void) {
        self.onProvidersChanged = onProvidersChanged
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    func hide() { window?.orderOut(nil) }

    // MARK: - 构建界面

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex"
        window.subtitle = "供应商热切换"
        window.titlebarSeparatorStyle = .line
        window.minSize = NSSize(width: 460, height: 520)
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        guard let content = window.contentView else { return }

        headerLabel = makeLabel("加载中…", font: .systemFont(ofSize: 22, weight: .bold), color: .labelColor)
        effectiveLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        effectiveLabel.lineBreakMode = .byTruncatingMiddle

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.style = .plain

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        reloadButton = NSButton(title: "重新加载", target: self, action: #selector(reloadNow))
        reloadButton.bezelStyle = .rounded
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新加载")
        reloadButton.imagePosition = .imageLeading
        reloadButton.controlSize = .large

        watchSwitch = makeSwitch(action: #selector(toggleWatch))
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        scopePopup = NSPopUpButton()
        scopePopup.controlSize = .small
        scopePopup.addItems(withTitles: ["仅主 app-server", "含 computer-use 会话", "全部（含其它 App）"])
        scopePopup.selectItem(at: scopeIndexFromDefaults())
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)

        focusSwitch = makeSwitch(action: #selector(toggleFocus))
        focusSwitch.state = (defaults.object(forKey: "focusChatGPT") as? Bool ?? true) ? .on : .off

        remoteSwitch = makeSwitch(action: #selector(toggleRemote))
        remoteSwitch.state = (defaults.object(forKey: "syncRemote") as? Bool ?? true) ? .on : .off

        loginSwitch = makeSwitch(action: #selector(toggleLogin))
        loginSwitch.state = Self.loginItemEnabled() ? .on : .off

        remoteRows = NSStackView()
        remoteRows.orientation = .vertical
        remoteRows.alignment = .leading
        remoteRows.spacing = 8
        rebuildRemoteRows()

        addRemoteButton = NSButton(title: "添加机器", target: self, action: #selector(addRemote))
        addRemoteButton.bezelStyle = .rounded
        addRemoteButton.controlSize = .small
        addRemoteButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加机器")
        addRemoteButton.imagePosition = .imageLeading

        statusLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        let providerCard = card(containing: scroll, insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        let actionRow = NSStackView(views: [reloadButton, flexibleSpace(), labeledSwitch(watchSwitch, title: "自动跟随"), spinner])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10

        let remoteHeader = NSStackView(views: [
            makeLabel("远程机器", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor),
            flexibleSpace(),
            labeledSwitch(remoteSwitch, title: "同步"),
        ])
        remoteHeader.orientation = .horizontal
        remoteHeader.alignment = .centerY
        let remoteBody = NSStackView(views: [remoteHeader, remoteRows, addRemoteButton])
        remoteBody.orientation = .vertical
        remoteBody.alignment = .leading
        remoteBody.spacing = 10
        let remoteCard = card(containing: remoteBody)

        let settings = NSStackView(views: [
            settingsLine("重启范围", scopePopup),
            settingsLine("热重启后聚焦 ChatGPT", focusSwitch),
            settingsLine("登录时启动", loginSwitch),
        ])
        settings.orientation = .vertical
        settings.spacing = 8
        let settingsCard = card(containing: settings)

        let stack = NSStackView(views: [
            makeLabel("当前供应商", font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor),
            headerLabel,
            effectiveLabel,
            sectionLabel("供应商"),
            providerCard,
            actionRow,
            sectionLabel("同步"),
            remoteCard,
            settingsCard,
            statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let page = NSScrollView()
        page.drawsBackground = false
        page.hasVerticalScroller = true
        page.autohidesScrollers = true
        page.documentView = stack
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)

        let clip = page.contentView
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
            {
                let bottom = stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
                bottom.priority = .defaultLow
                return bottom
            }(),
            providerCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            remoteCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            settingsCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 220),
        ])

        window.makeFirstResponder(tableView)
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text, font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSwitch(action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        return toggle
    }

    private func labeledSwitch(_ toggle: NSSwitch, title: String) -> NSView {
        let label = makeLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        let row = NSStackView(views: [label, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func settingsLine(_ title: String, _ control: NSView) -> NSView {
        let label = makeLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        let row = NSStackView(views: [label, flexibleSpace(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func card(containing view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)) -> NSView {
        let box = CardView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -insets.bottom),
        ])
        return box
    }

    private func rebuildRemoteRows() {
        guard remoteRows != nil else { return }
        for view in remoteRows.arrangedSubviews {
            remoteRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if remotes.machines.isEmpty {
            let empty = makeLabel("还没有远程机器", font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
            remoteRows.addArrangedSubview(empty)
            return
        }
        for machine in remotes.machines {
            remoteRows.addArrangedSubview(makeRemoteRow(machine))
        }
        remoteRows.alphaValue = remoteSwitch.state == .on ? 1 : 0.45
    }

    private func makeRemoteRow(_ machine: RemoteMachine) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = machine.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(remoteMachineToggled(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(machine.host)

        let title = NSTextField(labelWithString: machine.label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: machine.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let usage = NSTextField(labelWithString: usageText(for: machine.host))
        usage.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        usage.textColor = .secondaryLabelColor
        usage.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [title, detail, usage])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        var views: [NSView] = [toggle, texts, flexibleSpace()]
        if machine.builtin {
            let badge = makeLabel("内置", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
            views.append(badge)
        } else {
            let remove = NSButton()
            remove.bezelStyle = .inline
            remove.isBordered = false
            remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "移除")
            remove.imagePosition = .imageOnly
            remove.contentTintColor = .secondaryLabelColor
            remove.target = self
            remove.action = #selector(removeRemote(_:))
            remove.identifier = NSUserInterfaceItemIdentifier(machine.host)
            views.append(remove)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { providers.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ProviderRowView()
        view.active = providers[row].id == currentId
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let provider = providers[row]
        let isCurrent = provider.id == currentId

        let radio = NSImageView()
        radio.image = NSImage(systemSymbolName: isCurrent ? "largecircle.fill.circle" : "circle",
                              accessibilityDescription: isCurrent ? "当前" : "")
        radio.contentTintColor = isCurrent ? .controlAccentColor : .tertiaryLabelColor
        radio.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: provider.name)
        name.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingTail

        let model = NSTextField(labelWithString: [
            provider.model,
            provider.host,
            provider.catalogCount > 0 ? "目录\(provider.catalogCount)" : nil,
        ].compactMap { $0 }.joined(separator: " · "))
        model.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        model.textColor = .secondaryLabelColor

        let tag = NSTextField(labelWithString: provider.official ? "官方" : "")
        tag.font = .systemFont(ofSize: 10)
        tag.textColor = .tertiaryLabelColor

        let textStack = NSStackView(views: [name, model])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let rowStack = NSStackView(views: [radio, textStack, NSView(), tag])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 8
        rowStack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: container.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            radio.widthAnchor.constraint(equalToConstant: 16),
        ])
        if !provider.hasConfig || provider.official {
            container.alphaValue = 0.5
        }
        return container
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < providers.count, !busy else { return }
        let provider = providers[row]
        if provider.official {
            setStatus("「\(provider.name)」是官方供应商，请在 cc-switch 中切换")
            return
        }
        // cc-switch 在运行时：外部直接改 live 配置会被它回填到"它以为的当前卡片"，导致卡片内容错位。
        // 因此默认引导用户改用 cc-switch 切换（自动跟随会热重启，效果一致）。
        if ccSwitchRunning {
            let alert = NSAlert()
            alert.messageText = "建议在 cc-switch 里切换"
            alert.informativeText = """
            cc-switch 正在运行。若由本 App 直接改配置，cc-switch 可能把这份配置回填到它认为的当前卡片，            造成卡片内容错位（之前已发生过一次）。

            推荐：在 cc-switch 里点击「\(provider.name)」，本 App 会自动热重启 Codex，效果完全一样。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开 cc-switch")      // 1
            alert.addButton(withTitle: "强制切换")             // 2
            alert.addButton(withTitle: "取消")                 // 3
            NSApp.activate(ignoringOtherApps: true)
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/CC Switch.app"))
                setStatus("请在 cc-switch 里点击「\(provider.name)」，本 App 会自动热重启 Codex")
                return
            }
            if choice == .alertSecondButtonReturn {
                performSwitch(provider, force: true)
                return
            }
            return
        }
        performSwitch(provider)
    }

    // MARK: - 操作

    func refresh() {
        guard !busy else { return }
        setBusy(true, status: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // 先渲染列表，避免被后续的配置校验拖慢
                let result = try self.backend.list()
                DispatchQueue.main.async {
                    self.providers = result.providers
                    self.currentId = result.currentId
                    self.liveInfo = result.live
                    self.ccSwitchRunning = result.ccSwitchRunning ?? false
                    self.tableView.reloadData()
                    self.onProvidersChanged?(result.providers, result.currentId)
                    self.updateHeader(current: nil)
                }
                // 再异步取生效配置（启动一次性 app-server 校验）
                let current = try? self.backend.current()
                DispatchQueue.main.async {
                    self.updateHeader(current: current)
                    self.setBusy(false)
                    self.refreshRemoteLive()
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateHeader(current: CurrentResult?) {
        // 以 config.toml（Codex 真正读取的文件）为准展示"正在使用谁"
        let live = liveInfo
        let liveProvider = live?.liveProviderId.flatMap { id in providers.first { $0.id == id } }
            ?? live?.matchedIds?.first.flatMap { id in providers.first { $0.id == id } }

        if let provider = liveProvider ?? providers.first(where: { $0.id == currentId }) {
            var title = "\(provider.name) · \(provider.model ?? "-")"
            if let host = live?.host, host != provider.host {
                title += "  →  \(host)"
            }
            headerLabel.stringValue = title
        } else {
            headerLabel.stringValue = "(未知)"
        }

        var lines: [String] = []
        if let live, let host = live.host {
            lines.append("实际端点: \(host)")
        }
        if let tail = live?.tokenTail {
            lines.append("key …\(tail)")
        }
        if let current, let eff = current.effective, eff.ok {
            lines.append(eff.hasToken == true ? "token ✔" : "token ✗")
        }
        effectiveLabel.stringValue = lines.joined(separator: "   ")

        // 一致性提示
        var notes: [String] = []
        if let live, let matched = live.matchedIds, matched.count > 1 {
            let names = matched.compactMap { id in providers.first { $0.id == id }?.name }
            if let used = liveProvider?.name {
                notes.append("「\(names.joined(separator: "」「"))」内容相同，实际使用其中的「\(used)」")
            }
        }
        if let live, let liveId = live.liveProviderId, let cur = currentId, liveId != cur {
            let a = providers.first { $0.id == cur }?.name ?? cur
            let b = providers.first { $0.id == liveId }?.name ?? liveId
            notes.append("⚠️ cc-switch 记录的是「\(a)」，但实际配置来自「\(b)」")
        }
        if !notes.isEmpty {
            setStatus("ℹ️ " + notes.joined(separator: "；"))
        }
    }

    private func performSwitch(_ provider: ProviderSummary, force: Bool = false) {
        setBusy(true, status: "正在切换到 \(provider.name)…")
        let scope = scopeCode()
        let focus = focusSwitch.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.backend.switchProvider(provider.id, scope: scope, focus: focus, force: force, remote: self.syncRemoteEnabled())
                NotificationCenter.default.post(name: .configWrittenFromApp, object: nil)
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.applyRemoteLive(result.remote)
                    self.refresh()
                    var parts = ["✔ 已切换到 \(provider.name)"]
                    if let model = result.effective?.model { parts.append("模型 \(model)") }
                    if let reload = result.reload {
                        if (reload.killed ?? 0) > 0 {
                            parts.append("已强制重启：在 ChatGPT 里点一次「Restart ChatGPT」")
                        } else if reload.respawned != nil {
                            parts.append("app-server 已自动重启，立即生效")
                        } else if (reload.terminated ?? 0) > 0 {
                            parts.append("点一下任意对话即生效，无需重启 Codex")
                        } else {
                            parts.append("下次启动 Codex 时生效")
                        }
                    }
                    if let warnings = result.warnings, !warnings.isEmpty {
                        parts.append("⚠️ " + warnings.joined(separator: "；"))
                    }
                    if let remote = self.remoteSummary(result.remote) { parts.append(remote) }
                    self.setStatus(parts.joined(separator: " · "))
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func reloadNow() {
        guard !busy else { return }
        setBusy(true, status: "正在重新加载 Codex…")
        let scope = scopeCode()
        let focus = focusSwitch.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.backend.reload(scope: scope, focus: focus, remote: self.syncRemoteEnabled())
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.applyRemoteLive(result.remote)
                    self.refresh()
                    let detail = result.reload
                    var text: String
                    if detail?.respawned != nil {
                        text = "✔ app-server 已自动重启，新供应商已生效"
                    } else if (detail?.killed ?? 0) > 0 {
                        text = "✔ 已强制重启：在 ChatGPT 里点一次「Restart ChatGPT」"
                    } else if (detail?.terminated ?? 0) > 0 {
                        text = "✔ 已重启 app-server，点一下任意对话即生效"
                    } else {
                        text = "ℹ️ 当前没有运行中的 app-server，下次启动 Codex 时生效"
                    }
                    if let remote = self.remoteSummary(result.remote) { text += " · \(remote)" }
                    self.setStatus(text)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    /// 外部（cc-switch 或自身）改动配置后的自动热重启。
    func autoReloadAfterChange(onDone: (() -> Void)? = nil) {
        guard !busy else { return }
        setBusy(true, status: "检测到配置变化，正在热重启 Codex…")
        let scope = scopeCode()
        let focus = focusSwitch.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.backend.reload(scope: scope, focus: focus, remote: self.syncRemoteEnabled())
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.applyRemoteLive(result.remote)
                    self.refresh()
                    var text: String
                    if result.reload?.respawned != nil {
                        text = "⚡ 已自动跟随切换：app-server 已重启，立即生效"
                    } else if (result.reload?.terminated ?? 0) > 0 || (result.reload?.killed ?? 0) > 0 {
                        text = "⚡ 已自动跟随切换，点一下任意对话即生效"
                    } else {
                        text = "⚡ 配置已变更（当前无运行中的 app-server）"
                    }
                    if let remote = self.remoteSummary(result.remote) { text += " · \(remote)" }
                    self.setStatus(text)
                    onDone?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus("❌ 自动跟随失败: \(error.localizedDescription)")
                    onDone?()
                }
            }
        }
    }

    @objc private func toggleWatch() {
        let enabled = watchSwitch.state == .on
        defaults.set(enabled, forKey: "watchEnabled")
        NotificationCenter.default.post(name: .watchToggled, object: nil)
        setStatus(enabled ? "已开启自动跟随：在 cc-switch 里切换供应商后 Codex 会自动生效" : "已关闭自动跟随")
    }

    func setWatchState(_ running: Bool) {
        guard watchSwitch != nil else { return }
        watchSwitch.state = running ? .on : .off
    }

    @objc private func scopeChanged() {
        defaults.set(scopeCode(), forKey: "scope")
    }

    @objc private func toggleFocus() {
        defaults.set(focusSwitch.state == .on, forKey: "focusChatGPT")
    }

    @objc private func toggleRemote() {
        defaults.set(remoteSwitch.state == .on, forKey: "syncRemote")
        rebuildRemoteRows()
        setStatus(remoteSwitch.state == .on ? "已开启远程同步" : "已关闭远程同步")
    }

    private func syncRemoteEnabled() -> Bool {
        if remoteSwitch != nil { return remoteSwitch.state == .on }
        return defaults.object(forKey: "syncRemote") as? Bool ?? true
    }

    @objc private func remoteMachineToggled(_ sender: NSSwitch) {
        guard let host = sender.identifier?.rawValue else { return }
        remotes.setEnabled(host: host, enabled: sender.state == .on)
        let name = remotes.machines.first { $0.host == host }?.label ?? host
        setStatus(sender.state == .on ? "\(name) 会参与同步" : "已暂停同步 \(name)")
    }

    @objc private func removeRemote(_ sender: NSButton) {
        guard let host = sender.identifier?.rawValue else { return }
        let name = remotes.machines.first { $0.host == host }?.label ?? host
        remotes.remove(host: host)
        rebuildRemoteRows()
        setStatus("已移除 \(name)")
    }

    @objc private func addRemote() {
        presentAddSheet()
    }

    private func usageText(for host: String) -> String {
        guard let live = remoteLive[host] else { return "正在读取…" }
        if !live.ok { return live.error ?? "读取失败" }
        let name = live.providerName ?? "未命名"
        let endpoint = live.baseUrl.flatMap { URL(string: $0)?.host } ?? live.baseUrl ?? "—"
        let key = live.tokenTail.map { "key …\($0)" } ?? "key —"
        return "\(name) · \(endpoint) · \(key)"
    }

    private func refreshRemoteLive() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = try? self.backend.remoteStatus()
            DispatchQueue.main.async {
                guard let result else {
                    self.setStatus("远程状态读取失败")
                    return
                }
                var next: [String: RemoteHostInfo] = [:]
                for host in result.hosts {
                    next[host.host] = host
                }
                self.remoteLive = next
                self.rebuildRemoteRows()
            }
        }
    }

    private func applyRemoteLive(_ remote: RemoteSyncInfo?) {
        guard let remote else { return }
        for host in remote.hosts where host.ok {
            remoteLive[host.host] = host
        }
        rebuildRemoteRows()
    }

    private func remoteSummary(_ remote: RemoteSyncInfo?) -> String? {
        guard let remote, !remote.hosts.isEmpty else { return nil }
        let parts = remote.hosts.map { host -> String in
            if !host.ok { return "\(host.label) 失败" }
            if host.changed { return "\(host.label) 已同步" }
            return "\(host.label) 已一致"
        }
        var text = "远程 " + parts.joined(separator: "、")
        if let error = remote.hosts.first(where: { !$0.ok })?.error, !error.isEmpty {
            text += "（\(error)）"
        }
        return text
    }

    @objc private func toggleLogin() {
        do {
            if loginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            setStatus(loginSwitch.state == .on ? "已设置登录时启动" : "已取消登录时启动")
        } catch {
            loginSwitch.state = loginSwitch.state == .on ? .off : .on
            setStatus("设置登录启动失败: \(error.localizedDescription)")
        }
    }

    static func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func scopeCode() -> String {
        switch scopePopup.indexOfSelectedItem {
        case 1: return "chatgpt-all"
        case 2: return "all"
        default: return "chatgpt"
        }
    }

    private func scopeIndexFromDefaults() -> Int {
        switch defaults.string(forKey: "scope") ?? "chatgpt" {
        case "chatgpt-all": return 1
        case "all": return 2
        default: return 0
        }
    }

    // MARK: - 状态

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func setBusy(_ value: Bool, status: String? = nil) {
        busy = value
        reloadButton.isEnabled = !value
        tableView.isEnabled = !value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        addRemoteButton?.isEnabled = !value
        if let status { setStatus(status) }
    }

    private func presentAddSheet() {
        let labelField = formField("例如 gpu")
        let hostField = formField("主机名或 IP")
        let userField = formField("留空则用 SSH config")
        let portField = formField("22")
        let keyField = formField("留空则用 SSH config")
        portField.stringValue = ""

        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseIdentity(_:)))
        choose.bezelStyle = .rounded
        choose.controlSize = .small
        choose.identifier = NSUserInterfaceItemIdentifier("identity-picker")
        objc_setAssociatedObject(choose, &identityFieldKey, keyField, .OBJC_ASSOCIATION_RETAIN)

        let keyRow = NSStackView(views: [keyField, choose])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let grid = NSGridView(views: [
            [formCaption("名称"), labelField],
            [formCaption("主机"), hostField],
            [formCaption("用户"), userField],
            [formCaption("端口"), portField],
            [formCaption("私钥"), keyRow],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAddSheet(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "添加", target: self, action: #selector(confirmAddSheet(_:)))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        objc_setAssociatedObject(save, &addSheetFieldsKey, [labelField, hostField, userField, portField, keyField], .OBJC_ASSOCIATION_RETAIN)

        let buttons = NSStackView(views: [flexibleSpace(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let hint = makeLabel("认证使用 SSH 密钥。没有写在 SSH config 里的机器，请填用户和私钥。", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping

        let body = NSStackView(views: [grid, hint, buttons])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        body.translatesAutoresizingMaskIntoConstraints = false

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "添加远程机器"
        let sheetContent = NSView()
        sheet.contentView = sheetContent
        sheetContent.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: sheetContent.topAnchor),
            body.leadingAnchor.constraint(equalTo: sheetContent.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: sheetContent.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: sheetContent.bottomAnchor),
            grid.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
            hint.widthAnchor.constraint(equalTo: grid.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        window.beginSheet(sheet)
    }

    @objc private func cancelAddSheet(_ sender: NSButton) {
        guard let sheet = sender.window else { return }
        window.endSheet(sheet)
    }

    @objc private func confirmAddSheet(_ sender: NSButton) {
        guard let sheet = sender.window,
              let fields = objc_getAssociatedObject(sender, &addSheetFieldsKey) as? [NSTextField],
              fields.count == 5 else { return }
        let portText = fields[3].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var port: Int?
        if !portText.isEmpty {
            guard let value = Int(portText), (1...65535).contains(value) else {
                setStatus("端口需要是 1 到 65535 的数字")
                return
            }
            port = value
        }
        do {
            try remotes.add(
                label: fields[0].stringValue,
                host: fields[1].stringValue,
                user: fields[2].stringValue,
                port: port,
                identityFile: fields[4].stringValue
            )
            rebuildRemoteRows()
            setStatus("已添加 \(fields[0].stringValue.isEmpty ? fields[1].stringValue : fields[0].stringValue)")
            window.endSheet(sheet)
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    @objc private func chooseIdentity(_ sender: NSButton) {
        guard let field = objc_getAssociatedObject(sender, &identityFieldKey) as? NSTextField else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                field.stringValue = url.path
            }
        }
    }

    private func formField(_ placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return field
    }

    private func formCaption(_ text: String) -> NSTextField {
        let label = makeLabel(text, font: .systemFont(ofSize: 13), color: .labelColor)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 36).isActive = true
        return label
    }
}

private var addSheetFieldsKey: UInt8 = 0
private var identityFieldKey: UInt8 = 0

final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
}

final class ProviderRowView: NSTableRowView {
    var active = false

    override func drawSelection(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        if active {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            let rect = bounds.insetBy(dx: 6, dy: 3)
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

extension Notification.Name {
    static let watchToggled = Notification.Name("codex-hotswitch.watchToggled")
    static let configWrittenFromApp = Notification.Name("codex-hotswitch.configWrittenFromApp")
}
