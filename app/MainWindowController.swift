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
    private var ccRows: NSStackView!
    private var codexSidebar: SidebarRow!
    private var ccSidebar: SidebarRow!
    private var codexPane: NSStackView!
    private var ccPane: NSStackView!
    private var ccSyncSwitch: NSSwitch!
    private var ccStatusLabel: NSTextField!
    private var addRemoteButton: NSButton!
    private let remotes = RemoteStore.shared

    private let backend = Backend.shared
    private var providers: [ProviderSummary] = []
    private var currentId: String?
    private var liveInfo: LiveInfo?
    private var remoteLive: [String: RemoteHostInfo] = [:]
    private var ccSwitchLive: [String: CcSwitchHostInfo] = [:]
    private var ccSwitchTimer: Timer?
    private var ccSwitchBusy = false
    private var ccSwitchHash: String?
    private var ccSwitchPending = Set<String>()
    private var ccSwitchAttempts: [String: Int] = [:]
    private var ccSwitchBootstrapped = false
    private var ccSwitchLastAttempt = Date.distantPast
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex"
        window.subtitle = "供应商热切换"
        window.titlebarSeparatorStyle = .automatic
        window.minSize = NSSize(width: 700, height: 560)
        window.isRestorable = false
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        guard let content = window.contentView else { return }

        headerLabel = makeLabel("加载中…", font: .systemFont(ofSize: 20, weight: .semibold), color: .labelColor)
        effectiveLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        effectiveLabel.lineBreakMode = .byTruncatingMiddle

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 48
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
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 12)

        reloadButton = NSButton(title: "重新加载", target: self, action: #selector(reloadNow))
        reloadButton.bezelStyle = .rounded
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新加载")
        reloadButton.imagePosition = .imageLeading
        reloadButton.controlSize = .regular

        watchSwitch = makeSwitch(action: #selector(toggleWatch))
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        scopePopup = NSPopUpButton()
        scopePopup.controlSize = .regular
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

        addRemoteButton = linkButton(title: "添加机器", symbol: "plus", action: #selector(addRemote))

        remoteRows = NSStackView()
        remoteRows.orientation = .vertical
        remoteRows.alignment = .leading
        remoteRows.spacing = 0
        rebuildRemoteRows()
        let remoteCard = card(containing: remoteRows, insets: NSEdgeInsets())

        statusLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        codexSidebar = SidebarRow(title: "Codex", symbol: "arrow.left.arrow.right")
        ccSidebar = SidebarRow(title: "cc-switch", symbol: "arrow.triangle.2.circlepath")
        codexSidebar.onClick = { [weak self] in self?.selectPage(0) }
        ccSidebar.onClick = { [weak self] in self?.selectPage(1) }

        let providerCard = card(containing: scroll, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        let actionRow = NSStackView(views: [reloadButton, spinner, flexibleSpace(), labeledSwitch(watchSwitch, title: "自动跟随")])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let settings = groupedStack([
            settingsLine("重启范围", scopePopup),
            settingsLine("热重启后聚焦 ChatGPT", focusSwitch),
            settingsLine("登录时启动", loginSwitch),
        ])
        let settingsCard = card(containing: settings, insets: NSEdgeInsets())

        let hero = NSStackView(views: [
            makeLabel("当前供应商", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor),
            headerLabel,
            effectiveLabel,
        ])
        hero.orientation = .vertical
        hero.alignment = .leading
        hero.spacing = 2

        codexPane = NSStackView(views: [
            hero,
            sectionBlock("供应商", providerCard),
            actionRow,
            sectionBlock("远程机器", remoteCard),
            sectionBlock("通用", settingsCard),
            statusLabel,
        ])
        codexPane.orientation = .vertical
        codexPane.alignment = .leading
        codexPane.spacing = 18

        ccSyncSwitch = makeSwitch(action: #selector(toggleCcSync))
        ccSyncSwitch.state = (defaults.object(forKey: "syncCcSwitch") as? Bool ?? true) ? .on : .off
        ccRows = NSStackView()
        ccRows.orientation = .vertical
        ccRows.alignment = .leading
        ccRows.spacing = 0
        rebuildCcRows()
        ccStatusLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        ccStatusLabel.lineBreakMode = .byWordWrapping
        ccStatusLabel.maximumNumberOfLines = 3
        ccStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let ccCard = card(containing: ccRows, insets: NSEdgeInsets())
        ccPane = NSStackView(views: [
            sectionBlock("远程机器", ccCard),
            ccStatusLabel,
        ])
        ccPane.orientation = .vertical
        ccPane.alignment = .leading
        ccPane.spacing = 10

        let stack = NSStackView(views: [codexPane, ccPane])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let page = NSScrollView()
        page.drawsBackground = true
        page.backgroundColor = Chrome.page
        page.scrollerStyle = .overlay
        page.hasVerticalScroller = true
        page.autohidesScrollers = true
        page.documentView = stack
        page.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let sidebarRows = NSStackView(views: [codexSidebar, ccSidebar])
        sidebarRows.orientation = .vertical
        sidebarRows.alignment = .leading
        sidebarRows.spacing = 2
        sidebarRows.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        sidebarRows.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarRows)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setContentHuggingPriority(.defaultLow, for: .vertical)
        divider.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sidebar.setContentHuggingPriority(.defaultLow, for: .vertical)
        page.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.addSubview(sidebar)
        content.addSubview(divider)
        content.addSubview(page)

        let clip = page.contentView
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 212),
            sidebarRows.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarRows.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarRows.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            codexSidebar.widthAnchor.constraint(equalTo: sidebarRows.widthAnchor, constant: -16),
            ccSidebar.widthAnchor.constraint(equalTo: sidebarRows.widthAnchor, constant: -16),
            codexSidebar.heightAnchor.constraint(equalToConstant: 48),
            ccSidebar.heightAnchor.constraint(equalToConstant: 48),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
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
            codexPane.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            ccPane.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            providerCard.widthAnchor.constraint(equalTo: codexPane.widthAnchor),
            remoteCard.widthAnchor.constraint(equalTo: codexPane.widthAnchor),
            settingsCard.widthAnchor.constraint(equalTo: codexPane.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: codexPane.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: codexPane.widthAnchor),
            ccCard.widthAnchor.constraint(equalTo: ccPane.widthAnchor),
            ccStatusLabel.widthAnchor.constraint(equalTo: ccPane.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),
        ])

        showPage(defaults.integer(forKey: "mainPage") == 1 ? 1 : 0)
        window.setContentSize(NSSize(width: 760, height: 720))
        window.makeFirstResponder(tableView)
        if ccSyncEnabled() { startCcSwitchFollow() }
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text, font: .systemFont(ofSize: 13, weight: .bold), color: .labelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func sectionBlock(_ title: String, _ content: NSView) -> NSStackView {
        let block = NSStackView(views: [sectionLabel(title), content])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 6
        return block
    }

    private func linkButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 13)
        return button
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

    private func hugLeading(_ view: NSView) -> NSView {
        view.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [view, flexibleSpace()])
        row.orientation = .horizontal
        row.alignment = .centerY
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

    private func groupedStack(_ rows: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for row in rows { addGrouped(stack, row) }
        return stack
    }

    private func addGrouped(_ stack: NSStackView, _ view: NSView) {
        if !stack.arrangedSubviews.isEmpty {
            let line = separatorRow()
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let row = padded(view, NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 12))
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func padded(_ content: NSView, _ insets: NSEdgeInsets) -> NSView {
        let wrap = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrap.topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -insets.bottom),
        ])
        return wrap
    }

    private func separatorRow() -> NSView {
        let wrap = NSView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrap
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
        addGrouped(remoteRows, settingsLine("同步这些机器", remoteSwitch))
        if remotes.machines.isEmpty {
            addGrouped(remoteRows, makeLabel("还没有远程机器", font: .systemFont(ofSize: 13), color: .tertiaryLabelColor))
        } else {
            let dimmed = remoteSwitch.state != .on
            for machine in remotes.machines {
                let row = makeRemoteRow(machine)
                if dimmed { row.alphaValue = 0.45 }
                addGrouped(remoteRows, row)
            }
        }
        if addRemoteButton != nil { addGrouped(remoteRows, hugLeading(addRemoteButton)) }
        rebuildCcRows()
    }

    private func rebuildCcRows() {
        guard ccRows != nil, ccSyncSwitch != nil else { return }
        for view in ccRows.arrangedSubviews {
            ccRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        addGrouped(ccRows, makeCcSyncRow())
        if remotes.machines.isEmpty {
            addGrouped(ccRows, makeLabel("还没有远程机器。可在 Codex 页添加。", font: .systemFont(ofSize: 13), color: .tertiaryLabelColor))
        } else {
            let dimmed = !ccSyncEnabled()
            for machine in remotes.machines {
                let row = makeCcRow(machine)
                if dimmed { row.alphaValue = 0.45 }
                addGrouped(ccRows, row)
            }
        }
        addGrouped(ccRows, hugLeading(linkButton(title: "立即检查", symbol: "arrow.clockwise", action: #selector(checkCcSwitchNow))))
    }

    private func makeCcSyncRow() -> NSView {
        let title = makeLabel("实时同步", font: .systemFont(ofSize: 13), color: .labelColor)
        let detail = makeLabel("以本机 cc-switch 为准。配置一变就推到远程；没连上的机器会等到连上，再检查并更新。", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 400
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [texts, flexibleSpace(), ccSyncSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func makeCcRow(_ machine: RemoteMachine) -> NSView {
        let title = NSTextField(labelWithString: machine.label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: machine.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let appearance = ccSwitchAppearance(for: machine)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: appearance.text)
        icon.contentTintColor = appearance.tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let state = NSTextField(labelWithString: appearance.text)
        state.font = .systemFont(ofSize: 12)
        state.textColor = appearance.tint
        state.lineBreakMode = .byTruncatingTail
        let status = NSStackView(views: [icon, state])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 4

        let row = NSStackView(views: [texts, flexibleSpace(), status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
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

        var trailing: [NSView] = []
        if machine.builtin {
            trailing.append(makeLabel("内置", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor))
        } else {
            let remove = NSButton()
            remove.bezelStyle = .inline
            remove.isBordered = false
            remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "移除")
            remove.imagePosition = .imageOnly
            remove.contentTintColor = .secondaryLabelColor
            remove.target = self
            remove.action = #selector(removeRemote(_:))
            remove.identifier = NSUserInterfaceItemIdentifier(machine.host)
            trailing.append(remove)
        }
        trailing.append(toggle)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [texts, flexibleSpace()] + trailing)
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

        let name = NSTextField(labelWithString: provider.name)
        name.font = .systemFont(ofSize: 13, weight: isCurrent ? .medium : .regular)
        name.lineBreakMode = .byTruncatingTail

        let model = NSTextField(labelWithString: [
            provider.model,
            provider.host,
            provider.catalogCount > 0 ? "目录\(provider.catalogCount)" : nil,
        ].compactMap { $0 }.joined(separator: " · "))
        model.font = .systemFont(ofSize: 12)
        model.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [name, model])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var trailing: [NSView] = []
        if provider.official {
            let tag = NSTextField(labelWithString: "官方")
            tag.font = .systemFont(ofSize: 11)
            tag.textColor = .tertiaryLabelColor
            trailing.append(tag)
        }
        let mark = NSImageView()
        mark.image = isCurrent ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "当前") : nil
        mark.contentTintColor = .controlAccentColor
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        mark.translatesAutoresizingMaskIntoConstraints = false
        trailing.append(mark)

        let rowStack = NSStackView(views: [textStack, flexibleSpace()] + trailing)
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 8
        rowStack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: container.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mark.widthAnchor.constraint(equalToConstant: 14),
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
            cc-switch 正在运行。若由本 App 直接改配置，cc-switch 可能把这份配置回填到它认为的当前卡片，造成卡片内容错位。

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
        refreshSidebar()
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
        refreshSidebar()
        setStatus(remoteSwitch.state == .on ? "已开启 Codex 远程同步" : "已关闭 Codex 远程同步")
    }

    func selectPage(_ index: Int) {
        let page = index == 1 ? 1 : 0
        defaults.set(page, forKey: "mainPage")
        showPage(page)
    }

    private func showPage(_ index: Int) {
        codexPane?.isHidden = index != 0
        ccPane?.isHidden = index != 1
        window?.subtitle = index == 1 ? "cc-switch 同步" : "供应商热切换"
        codexSidebar?.selected = index == 0
        ccSidebar?.selected = index == 1
        refreshSidebar()
    }

    private func refreshSidebar() {
        codexSidebar?.setDetail(codexSidebarDetail())
        ccSidebar?.setDetail(ccSidebarDetail())
    }

    private func codexSidebarDetail() -> String {
        if let provider = providers.first(where: { $0.id == currentId }) {
            if let model = provider.model, !model.isEmpty { return "\(provider.name) · \(model)" }
            return provider.name
        }
        return "供应商热切换"
    }

    private func ccSidebarDetail() -> String {
        guard ccSyncEnabled() else { return "实时同步已关闭" }
        let enabled = remotes.machines.filter(\.enabled)
        if enabled.isEmpty { return "没有远程机器" }
        let lives = enabled.compactMap { ccSwitchLive[$0.host] }
        if lives.count < enabled.count { return "正在检查…" }
        let waiting = lives.filter(\.pending).count
        if waiting > 0 { return "\(waiting) 台等待连接" }
        let failed = lives.filter { !$0.ok }.count
        if failed > 0 { return "\(failed) 台需要处理" }
        return "已与本机一致"
    }

    func barHostLines() -> [(label: String, codex: String, ccswitch: String)] {
        remotes.machines.map { machine in
            let codex: String
            if !machine.enabled {
                codex = "已暂停"
            } else if let live = remoteLive[machine.host] {
                codex = live.ok ? (live.providerName ?? "已连接") : "未连接"
            } else {
                codex = "正在读取"
            }
            return (machine.label, codex, ccSwitchAppearance(for: machine).text)
        }
    }

    func setRemoteSyncEnabled(_ enabled: Bool) {
        guard remoteSwitch != nil else {
            defaults.set(enabled, forKey: "syncRemote")
            return
        }
        guard (remoteSwitch.state == .on) != enabled else { return }
        remoteSwitch.state = enabled ? .on : .off
        toggleRemote()
    }

    func setCcSyncEnabled(_ enabled: Bool) {
        guard ccSyncSwitch != nil else {
            defaults.set(enabled, forKey: "syncCcSwitch")
            return
        }
        guard (ccSyncSwitch.state == .on) != enabled else { return }
        ccSyncSwitch.state = enabled ? .on : .off
        toggleCcSync()
    }

    func checkCcSwitchFromMenu() {
        checkCcSwitchNow()
    }

    var remoteSyncIsOn: Bool { syncRemoteEnabled() }
    var ccSyncIsOn: Bool { ccSyncEnabled() }

    @objc private func toggleCcSync() {
        defaults.set(ccSyncSwitch.state == .on, forKey: "syncCcSwitch")
        rebuildCcRows()
        if ccSyncSwitch.state == .on {
            ccSwitchBootstrapped = false
            startCcSwitchFollow()
            setCcStatus("已开启实时同步")
        } else {
            stopCcSwitchFollow()
            setCcStatus("已关闭实时同步")
        }
        refreshSidebar()
    }

    @objc private func checkCcSwitchNow() {
        guard !ccSwitchBusy else { return }
        ccSwitchBootstrapped = false
        ccSwitchPending.removeAll()
        setCcStatus("正在按本机检查远程 cc-switch…")
        if ccSyncSwitch.state == .on {
            startCcSwitchFollow()
        }
        tickCcSwitchFollow()
    }

    private func ccSyncEnabled() -> Bool {
        if ccSyncSwitch != nil { return ccSyncSwitch.state == .on }
        return defaults.object(forKey: "syncCcSwitch") as? Bool ?? true
    }

    private func setCcStatus(_ text: String) {
        ccStatusLabel?.stringValue = text
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

    private func ccSwitchAppearance(for machine: RemoteMachine) -> (symbol: String, tint: NSColor, text: String) {
        guard machine.enabled else { return ("pause.circle", .tertiaryLabelColor, "已暂停") }
        guard ccSyncEnabled() else { return ("pause.circle", .tertiaryLabelColor, "已关闭") }
        guard let live = ccSwitchLive[machine.host] else { return ("arrow.triangle.2.circlepath", .secondaryLabelColor, "正在检查…") }
        if live.pending {
            let waiting = live.error == "等待连接" || live.error == nil
            return ("clock", .secondaryLabelColor, waiting ? "等待连接" : (live.error ?? "等待连接"))
        }
        if !live.ok { return ("exclamationmark.circle", .systemRed, live.error.map { "失败：\($0)" } ?? "失败") }
        if live.changed { return ("checkmark.circle.fill", .systemGreen, "已按本机更新") }
        return ("checkmark.circle.fill", .systemGreen, "已与本机一致")
    }

    private func startCcSwitchFollow() {
        guard ccSwitchTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tickCcSwitchFollow()
        }
        RunLoop.main.add(timer, forMode: .common)
        ccSwitchTimer = timer
        tickCcSwitchFollow()
    }

    private func stopCcSwitchFollow() {
        ccSwitchTimer?.invalidate()
        ccSwitchTimer = nil
        ccSwitchBusy = false
    }

    private func tickCcSwitchFollow() {
        guard ccSyncEnabled(), !ccSwitchBusy else { return }
        let previous = ccSwitchHash
        let bootstrapped = ccSwitchBootstrapped
        let pending = ccSwitchPending
        let lastAttempt = ccSwitchLastAttempt
        ccSwitchBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let hash = try? self.backend.ccSwitchFingerprint() else {
                DispatchQueue.main.async { self.ccSwitchBusy = false }
                return
            }
            let localChanged = hash != previous
            let retryDue = !pending.isEmpty && Date().timeIntervalSince(lastAttempt) > 8
            guard localChanged || !bootstrapped || retryDue else {
                DispatchQueue.main.async { self.ccSwitchBusy = false }
                return
            }
            let onlyPending = !localChanged && bootstrapped
            do {
                if localChanged { Thread.sleep(forTimeInterval: 0.4) }
                let stable = try self.backend.ccSwitchFingerprint()
                let result = try self.backend.syncCcSwitch(hosts: onlyPending ? Array(pending) : nil)
                DispatchQueue.main.async {
                    self.applyCcSwitchResult(result, hash: stable, replacePending: !onlyPending)
                }
            } catch {
                DispatchQueue.main.async {
                    self.ccSwitchBusy = false
                    self.ccSwitchLastAttempt = Date()
                }
            }
        }
    }

    private func applyCcSwitchResult(_ result: CcSwitchSyncResult, hash: String, replacePending: Bool) {
        ccSwitchBusy = false
        ccSwitchHash = hash
        ccSwitchBootstrapped = true
        ccSwitchLastAttempt = Date()
        if replacePending { ccSwitchPending.removeAll() }
        var changedState = false
        for host in result.remote.hosts {
            let old = ccSwitchLive[host.host]
            if old?.ok != host.ok || old?.pending != host.pending || old?.changed != host.changed {
                changedState = true
            }
            ccSwitchLive[host.host] = host
            if host.ok {
                ccSwitchAttempts[host.host] = 0
                ccSwitchPending.remove(host.host)
            } else if host.pending || (ccSwitchAttempts[host.host] ?? 0) < 3 {
                ccSwitchAttempts[host.host] = (ccSwitchAttempts[host.host] ?? 0) + 1
                ccSwitchPending.insert(host.host)
            } else {
                ccSwitchPending.remove(host.host)
            }
        }
        if changedState { rebuildCcRows() }
        refreshSidebar()
        let updated = result.remote.hosts.filter { $0.ok && $0.changed }.map(\.label)
        if !updated.isEmpty {
            setCcStatus("已按本机更新 " + updated.joined(separator: "、"))
        } else if let waiting = result.remote.hosts.first(where: { $0.pending }) {
            let reason = waiting.error ?? "没连上"
            setCcStatus("\(waiting.label)：\(reason)。连上后会再检查")
        } else if result.remote.hosts.allSatisfy(\.ok) {
            setCcStatus("远程 cc-switch 已与本机一致")
        }
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
                self.refreshSidebar()
            }
        }
    }

    private func applyRemoteLive(_ remote: RemoteSyncInfo?) {
        guard let remote else { return }
        for host in remote.hosts where host.ok {
            remoteLive[host.host] = host
        }
        rebuildRemoteRows()
        refreshSidebar()
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

final class SidebarRow: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { applyStyle() } }

    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let detailField: NSTextField

    init(title: String, symbol: String) {
        titleField = NSTextField(labelWithString: title)
        detailField = NSTextField(labelWithString: " ")
        super.init(frame: .zero)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 11)
        detailField.lineBreakMode = .byTruncatingTail
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let texts = NSStackView(views: [titleField, detailField])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(texts)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            texts.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            texts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDetail(_ text: String) {
        detailField.stringValue = text
        setAccessibilityValue(text)
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.setFill()
            let rect = bounds.insetBy(dx: 6, dy: 2)
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func applyStyle() {
        titleField.textColor = selected ? .white : .labelColor
        detailField.textColor = selected ? NSColor.white.withAlphaComponent(0.86) : .secondaryLabelColor
        iconView.contentTintColor = selected ? .white : .secondaryLabelColor
        needsDisplay = true
    }
}

final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.card.cgColor
    }
}

final class ProviderRowView: NSTableRowView {
    var active = false

    override func drawSelection(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        if active {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            let rect = bounds.insetBy(dx: 4, dy: 2)
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

enum Chrome {
    static let page = NSColor(name: "codex.pageBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
            : NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1)
    }

    static let card = NSColor(name: "codex.cardBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1)
            : .white
    }
}

extension Notification.Name {
    static let watchToggled = Notification.Name("codex-hotswitch.watchToggled")
    static let configWrittenFromApp = Notification.Name("codex-hotswitch.configWrittenFromApp")
}
