import AppKit
import ChromiumBridge

// Test-only packaged entry point. Never reads normal workspace state or profiles.
@MainActor enum BrowserFixture {
    static var models: [BrowserModel] = []
    static var windows: [NSWindow] = []
    static func run(_ path: String) {
        func fail(_ field: String) -> Never {fputs("browser-fixture rejected field: \(field)\n", stderr); exit(2)}
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.neuraos.browser-smoke.") == true else {fail("CFBundleIdentifier")}
        guard let data = try? Data(contentsOf: URL(fileURLWithPath:path)),
              let config = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let tabs = config["tabs"] as? [[String:String]],
              let dataDirectory = config["dataDirectory"] as? String, !dataDirectory.isEmpty else {fail("fixture configuration")}
        guard Bundle.main.object(forInfoDictionaryKey:"NeuraDataDirectory") as? String == dataDirectory else {fail("NeuraDataDirectory")}
        guard let endpoint = config["endpoint"] as? String,
              let url = URL(string: endpoint), url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              Bundle.main.object(forInfoDictionaryKey:"NeuraEndpoint") as? String == endpoint else {fail("NeuraEndpoint")}
        guard tabs.allSatisfy({URL(string:$0["url"] ?? "")?.host == "127.0.0.1"}) else {fail("tab URL")}
        UserDefaults.standard.setVolatileDomain(["NeuraChromiumSmokeData":dataDirectory], forName:"NeuraChromiumSmoke")
        if let error = NCInitializeChromium() {fputs(error,stderr);exit(1)}
        NSApp.setActivationPolicy(.regular)
        for tab in tabs {mount(tab)}
        NSApp.activate(ignoringOtherApps:true)
        print("browser-fixture-ready");fflush(stdout)
        NSApp.run()
    }
    static func mount(_ tab: [String:String], view: NCChromiumView? = nil) {
        let workspace = tab["workspaceId"]!, project = tab["projectId"]!, id = tab["tabId"] ?? UUID().uuidString.lowercased()
        let storage = workspace+"."+id
        UserDefaults.standard.set(tab["url"],forKey:"browser."+storage)
        let model = BrowserModel(storageId:storage,workspaceId:workspace,projectId:project,view:view)
        models.append(model)
        let window = NSWindow(contentRect:NSRect(x:120,y:150,width:900,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "neuraOS Browser MCP fixture"
        model.view.frame = window.contentView!.bounds
        window.contentView!.addSubview(model.view)
        model.view.onPopup = {child,url in
            mount(["workspaceId":workspace,"projectId":project,"url":url],view:child);return true
        }
        model.view.onClosed = {BrowserAutomation.shared.unregister(model.view)}
        window.makeKeyAndOrderFront(nil)
        model.browserVisible = tab["hidden"] != "true"
        model.view.isHidden = !model.browserVisible
        windows.append(window)
    }
}
