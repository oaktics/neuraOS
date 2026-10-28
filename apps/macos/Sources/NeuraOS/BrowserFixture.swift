import AppKit
import ChromiumBridge

// Test-only packaged entry point. Never reads normal workspace state or profiles.
@MainActor enum BrowserFixture {
    static var models: [BrowserModel] = []
    static var windows: [NSWindow] = []
    static func run(_ path: String) {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.neuraos.browser-smoke.") == true,
              let data = try? Data(contentsOf: URL(fileURLWithPath:path)),
              let config = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let tabs = config["tabs"] as? [[String:String]],
              let dataDirectory = config["dataDirectory"] as? String, !dataDirectory.isEmpty,
              Bundle.main.object(forInfoDictionaryKey:"NeuraDataDirectory") as? String == dataDirectory,
              tabs.allSatisfy({URL(string:$0["url"] ?? "")?.host == "127.0.0.1"}) else {exit(2)}
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
