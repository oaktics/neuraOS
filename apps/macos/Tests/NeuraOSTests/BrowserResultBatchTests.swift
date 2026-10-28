import XCTest
@testable import NeuraOS

final class BrowserResultBatchTests: XCTestCase {
    func decoded(_ batch: BrowserResultBatch.Batch) throws -> [[String: Any]] {
        (try JSONSerialization.jsonObject(with:batch.data) as! [String:Any])["results"] as! [[String:Any]]
    }
    func testExactByteBoundaryAndSingleOversizeBecomeError() throws {
        let result: [String:Any] = ["id":"image","result":["data":String(repeating:"a",count:2048)]]
        let full = try BrowserResultBatch.make(nativeId:"native",tabs:[],results:[result])
        let exact = try BrowserResultBatch.make(nativeId:"native",tabs:[],results:[result],limit:full.data.count)
        XCTAssertNotNil(try decoded(exact)[0]["result"])
        let oversized = try BrowserResultBatch.make(nativeId:"native",tabs:[],results:[result],limit:full.data.count-1)
        XCTAssertEqual(try decoded(oversized)[0]["error"] as? String,"browser_image_too_large")
        XCTAssertEqual(oversized.ids,["image"])
    }
    func testAggregateSplitThenOversizeAndNormalResultMakeProgress() throws {
        let one: [String:Any] = ["id":"one","result":["data":String(repeating:"a",count:2048)]]
        let two: [String:Any] = ["id":"two","result":["data":String(repeating:"b",count:2048)]]
        let huge: [String:Any] = ["id":"huge","result":["data":String(repeating:"c",count:10000)]]
        let normal: [String:Any] = ["id":"read","result":["text":"recovered"]]
        var queue = [one,two,huge,normal], received = Set<String>(), errors: [String] = []
        for _ in 0..<4 where !queue.isEmpty {
            let batch = try BrowserResultBatch.make(nativeId:"native",tabs:[["title":"日本語\\\" title"]],results:queue,limit:3000)
            XCTAssertLessThanOrEqual(batch.data.count,3000);XCTAssertFalse(batch.ids.isEmpty)
            received.formUnion(batch.ids);errors += try decoded(batch).compactMap {$0["error"] as? String}
            queue.removeAll {batch.ids.contains($0["id"] as! String)}
        }
        XCTAssertTrue(queue.isEmpty);XCTAssertEqual(received,["one","two","huge","read"])
        XCTAssertEqual(errors,["browser_image_too_large"])
    }
    func testProductionBudgetCannotSendAnOversizePNG() throws {
        let result: [String:Any] = ["id":"huge","result":["data":String(repeating:"a",count:13*1024*1024)]]
        let batch = try BrowserResultBatch.make(nativeId:"native",tabs:[],results:[result,["id":"next","result":["ok":true]]])
        XCTAssertLessThan(batch.data.count,12*1024*1024)
        XCTAssertEqual(batch.ids,["huge","next"])
        XCTAssertEqual(try decoded(batch)[0]["error"] as? String,"browser_image_too_large")
    }
}
