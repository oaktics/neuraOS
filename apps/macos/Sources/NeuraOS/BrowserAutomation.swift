import AppKit
import ChromiumBridge

struct BrowserAutomationError: Error {let code: String}

// Runs only on the AppKit/CEF thread. The daemon cannot send arbitrary JS/CDP.
@MainActor final class BrowserAutomation {
    static let shared = BrowserAutomation()
    private struct Entry {weak var model: BrowserModel?}
    private var entries: [String: Entry] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var owners: [String: String] = [:]
    private var results: [[String: Any]] = []
    private let nativeId = UUID().uuidString.lowercased()
    private var loop: Task<Void, Never>?
    private var daemonInstance: String?
    private var monitor: Any?
    private let api = DaemonClient()
    private let session = URLSession(configuration: .ephemeral)
    func register(_ model: BrowserModel) {
        entries[model.storageId] = Entry(model: model)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                // Real human input cancels automation before the event is delivered.
                MainActor.assumeIsolated {
                    guard let self else {return}
                    for entry in self.entries.values {
                        guard let model = entry.model, !model.automationOwner.isEmpty, model.view.window === event.window else {continue}
                        if event.type == .keyDown || model.view.convert(model.view.bounds, to: nil).contains(event.locationInWindow) {self.stop(model)}
                    }
                }
                return event
            }
        }
        if loop == nil {loop = Task { [weak self] in
            while !Task.isCancelled {await self?.poll(); try? await Task.sleep(for: .milliseconds(200))}
        }}
    }
    func unregister(_ view: NCChromiumView) {
        for (key, entry) in entries where entry.model?.view === view {if let model = entry.model {stop(model)}; entries.removeValue(forKey: key)}
    }
    func stop(_ model: BrowserModel) {
        model.automationEnabled = false
        for (id, key) in owners where key == model.storageId {jobs[id]?.cancel()}
        model.view.cancelDevTools()
    }
    private func poll() async {
        let tabs: [[String: Any]] = entries.values.compactMap {entry in
            guard let m = entry.model else {return nil}
            return ["workspaceId":m.workspaceId,"tabId":m.tabId,"projectId":m.projectId,"url":String(m.address.prefix(8192)),"title":String(m.title.prefix(2048)),"selected":m.browserVisible,"loading":m.isLoading,"enabled":m.automationEnabled]
        }
        let sending = Array(results.prefix(32))
        do {
            var request = URLRequest(url: api.endpoint.appendingPathComponent("v1/browser/native/poll"))
            request.httpMethod = "POST"; request.timeoutInterval = 2
            let token = try String(contentsOf: api.dataDirectory.appendingPathComponent("daemon-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["nativeId":nativeId,"tabs":tabs,"results":sending])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {throw BrowserAutomationError(code: "browser_disconnected")}
            if let instance = body["instanceId"] as? String {
                if let previous = daemonInstance, previous != instance {
                    for job in jobs.values {job.cancel()}
                    for entry in entries.values {entry.model?.view.cancelDevTools()}
                }
                daemonInstance = instance
            }
            let sentIds = Set(sending.compactMap {$0["id"] as? String}); results.removeAll {sentIds.contains($0["id"] as? String ?? "")}
            for id in body["cancelIds"] as? [String] ?? [] {
                if let key = owners[id], let m = entries[key]?.model {jobs[id]?.cancel(); m.view.cancelDevTools()}
                else {results.append(["id":id,"error":"browser_cancelled"])}
            }
            for item in body["requests"] as? [[String: Any]] ?? [] {start(item)}
        } catch {
            for job in jobs.values {job.cancel()}
            for entry in entries.values {entry.model?.view.cancelDevTools()}
        }
        // Keep cancellation/results until acknowledged; never repeat side effects.
    }
    private func start(_ item: [String: Any]) {
        guard let id = item["id"] as? String, jobs[id] == nil,
              let c = item["command"] as? [String: Any], let workspaceId = c["workspaceId"] as? String,
              let tabId = c["tabId"] as? String, let projectId = item["projectId"] as? String,
              let deadline = item["deadline"] as? Double else {return}
        let key = workspaceId + "." + tabId
        guard let model = entries[key]?.model else {results.append(["id":id,"error":"browser_tab_closed"]);return}
        guard model.projectId == projectId else {results.append(["id":id,"error":"browser_forbidden"]);return}
        let action = c["action"] as? String ?? ""
        if action == "stop" {stop(model);results.append(["id":id,"result":["stopped":true]]);return}
        guard model.automationEnabled else {results.append(["id":id,"error":"browser_disabled"]);return}
        guard !owners.values.contains(key) else {results.append(["id":id,"error":"browser_busy"]);return}
        owners[id] = key; model.automationOwner = item["terminalId"] as? String ?? "CLI"
        jobs[id] = Task {
            defer {jobs.removeValue(forKey:id);owners.removeValue(forKey:id);model.automationOwner = ""}
            do {
                let result = try await Self.execute(c, view: model.view, deadline: deadline, allowed: {model.automationEnabled})
                results.append(["id":id,"result":result])
            } catch {results.append(["id":id,"error":(error as? BrowserAutomationError)?.code ?? "browser_cancelled"])}
        }
    }
    static func devTools(_ view: NCChromiumView, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let json = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8)!
        return try await withCheckedThrowingContinuation { continuation in
            view.devTools(method, parameters: json) {result, error in
                if let error {continuation.resume(throwing: BrowserAutomationError(code: error));return}
                guard let data = result?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {continuation.resume(throwing: BrowserAutomationError(code: "browser_protocol_error"));return}
                continuation.resume(returning: object)
            }
        }
    }
    static func execute(_ c: [String: Any], view: NCChromiumView, deadline: Double, allowed: () -> Bool = {true}) async throws -> [String: Any] {
        func check() throws {
            try Task.checkCancellation()
            guard allowed() else {throw BrowserAutomationError(code:"browser_disabled")}
            guard Date().timeIntervalSince1970 * 1000 < deadline else {throw BrowserAutomationError(code:"browser_timeout")}
        }
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {try check();let result = try await devTools(view, method, params);try check();return result}
        try check()
        let action = c["action"] as? String ?? ""
        if action == "screenshot" {
            // A hidden AppKit CEF view can return an all-white compositor surface.
            // Render the existing view for this capture, then restore visibility;
            // this never changes the selected workspace/tab or browser state.
            let hidden = view.isHidden
            view.beginAutomationCapture(); view.layoutSubtreeIfNeeded()
            defer {view.endAutomationCapture()}
            if hidden {try await Task.sleep(for:.milliseconds(150))}
            return try await call("Page.captureScreenshot", ["format":"png","captureBeyondViewport":false])
        }
        if action == "navigate" {
            guard let value = c["url"] as? String, let url = BrowserModel.navigationURL(value), url.absoluteString == value else {throw BrowserAutomationError(code:"browser_invalid_url")}
            let result = try await call("Page.navigate", ["url":value])
            if result["errorText"] != nil {throw BrowserAutomationError(code:"browser_navigation_failed")};return ["navigated":true]
        }
        if action == "wait" {
            let until = min(deadline, Date().timeIntervalSince1970*1000 + (c["timeoutMs"] as? Double ?? 5000))
            while Date().timeIntervalSince1970*1000 < until {
                do {
                    let value = try await execute(["action":"snapshot"],view:view,deadline:until,allowed:allowed)
                    if let text = value["text"] as? String, text.contains(c["text"] as? String ?? "") {return ["matched":true]}
                } catch let error as BrowserAutomationError where error.code == "browser_stale_ref" || error.code == "browser_protocol_error" {
                    // A navigation can replace the execution context while waiting.
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            throw BrowserAutomationError(code:"browser_timeout")
        }
        let tree = try await call("Page.getFrameTree")
        guard let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any], let frameId = frame["id"] as? String else {throw BrowserAutomationError(code:"browser_unavailable")}
        let world = try await call("Page.createIsolatedWorld", ["frameId":frameId,"worldName":"neuraos-browser-v1","grantUniveralAccess":false])
        guard let contextId = world["executionContextId"] as? Int else {throw BrowserAutomationError(code:"browser_unavailable")}
        func evaluate(_ command: [String: Any]) async throws -> [String: Any] {
            let json = String(data: try JSONSerialization.data(withJSONObject:command), encoding:.utf8)!
            let result = try await call("Runtime.evaluate", ["expression":"(\(script))(\(json))","contextId":contextId,"returnByValue":true,"userGesture":true])
            guard result["exceptionDetails"] == nil, let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] else {throw BrowserAutomationError(code:"browser_stale_ref")}
            if let error = value["error"] as? String {throw BrowserAutomationError(code:error)}
            return value
        }
        var command = c
        if action == "snapshot" {command["generation"] = UUID().uuidString.lowercased()}
        let result = try await evaluate(command)
        if action == "key" {
            let key = c["key"] as? String ?? ""
            let codes = ["Enter":13,"Tab":9,"Escape":27,"Backspace":8,"ArrowUp":38,"ArrowDown":40,"ArrowLeft":37,"ArrowRight":39]
            guard let code = codes[key] else {throw BrowserAutomationError(code:"browser_invalid_key")}
            _ = try await call("Input.dispatchKeyEvent", ["type":"keyDown","key":key,"code":key,"windowsVirtualKeyCode":code,"text":key == "Enter" ? "\r" : ""])
            _ = try await call("Input.dispatchKeyEvent", ["type":"keyUp","key":key,"code":key,"windowsVirtualKeyCode":code])
        }
        return result
    }
    // Fixed, isolated-world implementation. No page-provided script is executed.
    // A MutationObserver plus takeRecords rejects refs even before callbacks run.
    static let script = #"""
    (c) => {
      const visible=e=>e.isConnected&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
      if(c.action==='read')return {text:(document.body?.innerText||'').slice(0,60000)};
      if(c.action==='snapshot'){
        globalThis.__neura?.observer.disconnect();
        const state={generation:c.generation,dirty:false,refs:new Map()};
        state.observer=new MutationObserver(()=>state.dirty=true);
        state.observer.observe(document,{subtree:true,childList:true,attributes:true,characterData:true});
        globalThis.__neura=state;
        const elements=[];
        for(const e of [document.body,...document.querySelectorAll('a,button,input,textarea,select,[role],[tabindex],[contenteditable]')]){
          if(!e||!visible(e)||e.matches('input[type=password],input[autocomplete*=password],input[autocomplete=one-time-code]'))continue;
          if(elements.length>=500)break;
          const ref=state.generation+':'+elements.length;state.refs.set(ref,e);
          elements.push({ref,tag:e.tagName.toLowerCase(),role:e.getAttribute('role')||'',name:(e.getAttribute('aria-label')||e.getAttribute('placeholder')||e.innerText||'').slice(0,200),type:e.getAttribute('type')||''});
        }
        return {text:(document.body?.innerText||'').slice(0,60000),elements,scope:'main-frame',untrusted:true};
      }
      const s=globalThis.__neura;
      if(!s||s.dirty||s.observer.takeRecords().length)return {error:'browser_stale_ref'};
      const e=s.refs.get(c.ref);
      if(!e||!visible(e))return {error:'browser_stale_ref'};
      if(e.matches('input[type=password],input[autocomplete*=password],input[autocomplete=one-time-code]'))return {error:'browser_sensitive_field'};
      if(e.disabled||e.readOnly)return {error:'browser_element_disabled'};
      if(c.action==='click'){e.click();s.dirty=true;return {clicked:true};}
      if(c.action==='fill'){
        if(!e.matches('input:not([type=file]):not([type=hidden]),textarea'))return {error:'browser_not_text_field'};
        e.focus();const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto,'value').set.call(e,c.text);
        e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));s.dirty=true;return {filled:true};
      }
      if(c.action==='scroll'){if(e===document.body||e===document.documentElement)window.scrollBy(c.x,c.y);else e.scrollBy(c.x,c.y);s.dirty=true;return {scrolled:true,scrollX:window.scrollX,scrollY:window.scrollY};}
      if(c.action==='key'){e.focus();if(document.activeElement!==e)return {error:'browser_not_focusable'};s.dirty=true;return {focused:true};}
      return {error:'browser_unknown_action'};
    }
    """#
}
