import AppKit
import SwiftUI
import ChromiumBridge

/// AppKit owns the anchor so the extension surface is a real NSPopover.
struct BrowserExtensionToolbar: NSViewRepresentable {
    let browser: BrowserModel
    func makeNSView(context: Context) -> ExtensionToolbarView {ExtensionToolbarView(browser: browser)}
    func updateNSView(_ view: ExtensionToolbarView, context: Context) {
        if view.browser !== browser {view.popup.close(); view.browser = browser}
        view.synchronizeSource()
    }
    static func dismantleNSView(_ view: ExtensionToolbarView, coordinator: ()) {view.stop()}
}

final class ExtensionToolbarView: NSView, NSMenuDelegate {
    weak var browser: BrowserModel?
    private let fixtureSource: NCChromiumView
    private let fixtureAddress: String
    private var sourceView: NCChromiumView {browser?.view ?? fixtureSource}
    private var address: String {browser?.address ?? fixtureAddress}
    private var visible: Bool {browser?.browserVisible ?? true}
    let popup = NCExtensionPopover()
    private var lastAddress = ""
    private var actions: [NCExtensionAction] = []
    private let menuButton = NSButton()
    private let pinnedStrip = NSStackView()
    private let pinnedScroll = NSScrollView()
    private var timer: Timer?
    private var setupWindow: NSWindow?
    private var displayedPins: Set<String> = []
    private let pinsKey = "BrowserPinnedExtensionActions"
    private var pins: Set<String> {Set(UserDefaults.standard.stringArray(forKey: pinsKey) ?? [])}
    convenience init(browser: BrowserModel) {
        self.init(source: browser.view, address: browser.address)
        self.browser = browser
    }
    init(source: NCChromiumView, address: String) {
        fixtureSource = source; fixtureAddress = address
        super.init(frame: .zero)
        pinnedStrip.orientation = .horizontal; pinnedStrip.spacing = 2
        pinnedScroll.drawsBackground = false; pinnedScroll.hasHorizontalScroller = true
        pinnedScroll.scrollerStyle = .overlay; pinnedScroll.autohidesScrollers = true
        pinnedScroll.documentView = pinnedStrip
        addSubview(pinnedScroll)
        menuButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "拡張機能")
        menuButton.isBordered = false; menuButton.target = self; menuButton.action = #selector(showMenu)
        menuButton.toolTip = "拡張機能とピン留め"
        addSubview(menuButton)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, self.visible else {return}
                self.refresh()
            }
        }
    }
    required init?(coder: NSCoder) {fatalError("init(coder:) has not been implemented")}
    private var stripWidth: CGFloat {CGFloat(max(0, pinnedStrip.arrangedSubviews.count * 26 - 2))}
    override var intrinsicContentSize: NSSize {NSSize(width: min(154, stripWidth) + (stripWidth > 0 ? 2 : 0) + 24, height: 24)}
    override func layout() {
        super.layout()
        let width = min(stripWidth, max(0, bounds.width - 26))
        pinnedScroll.frame = NSRect(x: 0, y: (bounds.height - 24) / 2, width: width, height: 24)
        pinnedStrip.frame = NSRect(x: 0, y: 0, width: stripWidth, height: 24)
        menuButton.frame = NSRect(x: width + (width > 0 ? 2 : 0), y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
    func synchronizeSource() {
        if !visible || lastAddress != address {popup.close()}
        lastAddress = address
    }
    func stop() {
        timer?.invalidate(); timer = nil; popup.close()
        if let sheet = setupWindow {sheet.sheetParent?.endSheet(sheet); setupWindow = nil}
    }
    deinit {timer?.invalidate()}
    private func refresh() {
        let latest = NCExtensionActions()
        let changed = latest.map {"\($0.identifier)|\($0.title)|\($0.popupURL ?? "")"} != actions.map {"\($0.identifier)|\($0.title)|\($0.popupURL ?? "")"}
        actions = latest
        if changed {popup.close()}
        if changed || displayedPins != pins {rebuild()}
        if !sourceView.hasBrowser {popup.close()}
    }
    private func rebuild() {
        displayedPins = pins
        for view in pinnedStrip.arrangedSubviews {pinnedStrip.removeArrangedSubview(view); view.removeFromSuperview()}
        for action in actions where displayedPins.contains(action.identifier) {
            let button = NSButton(image: action.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!, target: self, action: #selector(openPinned(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action.identifier)
            button.imageScaling = .scaleProportionallyDown; button.isBordered = false
            button.toolTip = action.title; button.setAccessibilityLabel(action.title)
            pinnedStrip.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    @objc private func openPinned(_ sender: NSButton) {open(sender.identifier!.rawValue, anchor: sender)}
    private func open(_ id: String, anchor: NSView) {
        let error = popup.showExtension(id, from: anchor, source: sourceView)
        browser?.message = error
    }
    @objc private func showMenu() {
        refresh()
        let menu = NSMenu(); menu.delegate = self
        if actions.isEmpty {let item = menu.addItem(withTitle: "有効な拡張機能はありません", action: nil, keyEquivalent: ""); item.isEnabled = false}
        for action in actions {
            let item = NSMenuItem(title: action.title, action: #selector(openMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.identifier
            if let image = action.icon?.copy() as? NSImage {image.size = NSSize(width: 16, height: 16); item.image = image}
            menu.addItem(item)
            let pin = NSMenuItem(title: displayedPins.contains(action.identifier) ? "\(action.title) のピン留めを解除" : "\(action.title) をピン留め", action: #selector(togglePin(_:)), keyEquivalent: "")
            pin.target = self; pin.representedObject = action.identifier; pin.state = displayedPins.contains(action.identifier) ? .on : .off
            menu.addItem(pin)
        }
        menu.addItem(.separator())
        if actions.contains(where: {$0.identifier == OnePasswordIntegration.extensionID}) {
            let item = menu.addItem(withTitle: "1Password のデスクトップ連携を設定…", action: #selector(setupOnePassword), keyEquivalent: "")
            item.target = self
        }
        for (title, selector) in [("拡張機能を追加・管理…", #selector(manage)), ("このページを拡張対応ウィンドウで開く", #selector(fallback))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.maxY), in: menuButton)
    }
    @objc private func openMenuAction(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else {return}
        // Leave native menu tracking before creating/pumping a CEF surface.
        DispatchQueue.main.async { [weak self] in guard let self else {return}; self.open(id, anchor: self.menuButton) }
    }
    @objc private func togglePin(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else {return}
        var value = pins
        if !value.insert(id).inserted {value.remove(id)}
        UserDefaults.standard.set(value.sorted(), forKey: pinsKey); rebuild()
    }
    @objc private func setupOnePassword() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let parent = self.window, self.setupWindow == nil,
                  NCExtensionActions().contains(where: {$0.identifier == OnePasswordIntegration.extensionID}) else {return}
            self.popup.close()
            let sheet = NSWindow()
            sheet.contentViewController = NSHostingController(rootView: OnePasswordSetupView(onClose: { [weak self, weak sheet] in
                guard let sheet else {return}
                sheet.sheetParent?.endSheet(sheet)
                self?.setupWindow = nil
            }))
            self.setupWindow = sheet
            parent.beginSheet(sheet) { [weak self] _ in self?.setupWindow = nil }
        }
    }
    @objc private func manage() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}
            let error = NCOpenExtensionWindow("chrome://extensions/")
            self.browser?.message = error
        }
    }
    @objc private func fallback() {
        guard let url = BrowserModel.navigationURL(address) else {return}
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}
            let error = NCOpenExtensionWindow(url.absoluteString)
            self.browser?.message = error
        }
    }
}

/// Isolated smoke adapter for exercising the production toolbar, including pins.
/// The normal app never constructs this view.
final class ExtensionSmokeAccessory: NSView, NCExtensionsSmokeToolbarProviding {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let setup = NSHostingView(rootView: OnePasswordSetupView())
        setup.frame = bounds; setup.autoresizingMask = [.width, .height]; addSubview(setup)
    }
    convenience init() {self.init(frame: NSRect(x: 0, y: 0, width: 570, height: 590))}
    required init?(coder: NSCoder) {fatalError("init(coder:) has not been implemented")}
    func toolbar(forBrowser view: NCChromiumView, url: String) -> NSView? {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.neuraos.extensions-test") == true else {return nil}
        return ExtensionToolbarView(source: view, address: url)
    }
}
