import Foundation
import CryptoKit

public struct NativeRelease: Codable, Equatable {
    public let tag: String
    public let build: Int
    public let name: String
    public let digest: String
    public let url: String
    public var authenticated = false
    public static let repository = "oaktics/neuraOS"
    public static func validate(_ bytes: Data, architecture: String) throws -> NativeRelease {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["draft"] as? Bool != true, value["prerelease"] as? Bool != true,
              let tag = value["tag_name"] as? String, tag.range(of: "^native-[0-9]+$", options: .regularExpression) != nil,
              let build = Int(tag.dropFirst(7)), build > 0,
              let assets = value["assets"] as? [[String: Any]] else {throw UpdateFailure("対応する正式リリースではありません。")}
        let name = "neuraOS-darwin-\(architecture).zip"
        let url = "https://github.com/\(repository)/releases/download/\(tag)/\(name)"
        guard let asset = assets.first(where: {$0["name"] as? String == name}),
              let digest = asset["digest"] as? String, digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
              asset["browser_download_url"] as? String == url else {throw UpdateFailure("このMac用の検証可能な更新ファイルがありません。")}
        return NativeRelease(tag: tag, build: build, name: name, digest: String(digest.dropFirst(7)), url: url)
    }
    public func verify(file: URL) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer {try? input.close()}
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {hash.update(data: bytes)}
        guard hash.finalize().map({String(format: "%02x", $0)}).joined() == digest else {throw UpdateFailure("更新ファイルのSHA-256が一致しません。")}
    }
}

public struct ReleaseClient {
    public var run: CommandRunner = NativeCommand.run
    public init() {}
    public func latest() async throws -> NativeRelease {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let url = URL(string: "https://api.github.com/repos/\(NativeRelease.repository)/releases/latest")!
        do {
            let data = try await download(url, timeout: 30)
            return try NativeRelease.validate(data, architecture: arch)
        } catch {
            let result = try run("gh", ["api", "repos/\(NativeRelease.repository)/releases/latest"], 30)
            guard result.status == 0 else {throw UpdateFailure("更新を取得できません。ネット接続・gh auth loginを確認してください。")}
            var release = try NativeRelease.validate(Data(result.output.utf8), architecture: arch)
            release.authenticated = true
            return release
        }
    }
    public func downloadArchive(_ url: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600; configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer {session.invalidateAndCancel()}
        let (temporary, response) = try await session.download(from: url)
        defer {try? FileManager.default.removeItem(at: temporary)}
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw UpdateFailure("更新ファイルの取得に失敗しました。")}
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    public func download(_ url: URL, timeout: TimeInterval = 600) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer {session.invalidateAndCancel()}
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw UpdateFailure("更新ファイルの取得に失敗しました。")}
        return data
    }
}
