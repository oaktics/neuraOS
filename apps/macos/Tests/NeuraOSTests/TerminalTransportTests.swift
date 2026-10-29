import XCTest
import AppKit
import SwiftTerm
@testable import NeuraOS

private final class StalledOutputProtocol: URLProtocol {
    static var onOutput: (() -> Void)?
    static var onInput: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool {request.url?.host == "terminal-transport.invalid"}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
    override func startLoading() {
        if request.url!.path.hasSuffix("/output") {
            Self.onOutput?()
            // Deliberately leave the output response pending until cancellation.
        } else {
            Self.onInput?()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class TerminalTransportTests: XCTestCase {
    @MainActor func testInputDoesNotWaitForStalledOutputRequest() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture-only".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        defer {try? FileManager.default.removeItem(at: directory)}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledOutputProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer {transport.invalidateAndCancel()}
        let api = DaemonClient(endpoint: URL(string: "http://terminal-transport.invalid")!, dataDirectory: directory, session: transport)
        let outputStarted = expectation(description: "output request is stalled")
        let inputSent = expectation(description: "input uses independent request")
        StalledOutputProtocol.onOutput = {outputStarted.fulfill()}
        StalledOutputProtocol.onInput = {inputSent.fulfill()}
        defer {StalledOutputProtocol.onOutput = nil; StalledOutputProtocol.onInput = nil}
        let record = TerminalRecord(id: "fixture", workspaceId: "fixture", provider: "shell", status: "running", cols: 80, rows: 24)
        let coordinator = NativeTerminal.Coordinator(terminal: record, api: api, onError: {_ in XCTFail("Unexpected transport error")})
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        coordinator.view = view
        coordinator.setVisible(true)
        coordinator.caughtUp = true
        coordinator.start()
        defer {coordinator.stop()}
        await fulfillment(of: [outputStarted], timeout: 2)
        coordinator.send(source: view, data: Array("input".utf8)[...])
        await fulfillment(of: [inputSent], timeout: 2)
        XCTAssertTrue(coordinator.pendingInput.isEmpty)
        XCTAssertEqual(coordinator.cursor, 0)
    }
}
