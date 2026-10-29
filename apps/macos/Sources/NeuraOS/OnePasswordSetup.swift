import SwiftUI
import Security
import ChromiumBridge

enum OnePasswordIntegration {
    static let extensionURL = "https://chromewebstore.google.com/detail/1password/aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    static let helper = "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"
    static let manifestName = "com.1password.1password.json"

    enum SetupError: LocalizedError {
        case helperUnavailable, invalidSignature, profileUnavailable, existingRegistration
        var errorDescription: String? {
            switch self {
            case .helperUnavailable: return "1Password を Applications フォルダにインストールしてください。"
            case .invalidSignature: return "1Password ヘルパーの正規署名を確認できませんでした。1Password を更新して再試行してください。"
            case .profileUnavailable: return "ブラウザの保存先を確認できません。ブラウザを開いて再試行してください。"
            case .existingRegistration: return "既存の native messaging 登録があるため上書きしませんでした。保存先を確認してください。"
            }
        }
    }

    static func manifest() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "name": "com.1password.1password",
            "description": "1Password browser support",
            "path": helper,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"]
        ], options: [.prettyPrinted, .sortedKeys])
    }

    static func prepare(profile: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helper) else {throw SetupError.helperUnavailable}
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let identity = "anchor apple generic and identifier \"com.1password.browser-support\" and certificate leaf[subject.OU] = \"2BUA8C4S2C\""
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: helper) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {throw SetupError.invalidSignature}
        try register(manifest: manifest(), profile: profile)
    }

    // Chromium's standard user-level host registration. Never touches the
    // 1Password trust list or another browser's manifest/profile.
    static func register(manifest: Data, profile: URL) throws {
        let fm = FileManager.default
        let directory = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let destination = directory.appendingPathComponent(manifestName)
        guard fm.fileExists(atPath: profile.path),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {throw SetupError.profileUnavailable}
        if !fm.fileExists(atPath: directory.path) {try fm.createDirectory(at: directory, withIntermediateDirectories: false)}
        if fm.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == manifest else {throw SetupError.existingRegistration}
            return
        }
        try manifest.write(to: destination, options: .withoutOverwriting)
    }
}

struct OnePasswordSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1Password を設定").font(.title2.bold())
            Text("拡張機能は内蔵ブラウザ全体で共有されます。追加とサインインには専用ウィンドウを使います。")
            Button("1. 公式の1Password拡張を追加") {
                dismiss()
                DispatchQueue.main.async {if let error = NCOpenExtensionWindow(OnePasswordIntegration.extensionURL) {NSAlert(error: NSError(domain: "Chromium", code: 1, userInfo: [NSLocalizedDescriptionKey:error])).runModal()}}
            }
            Text("デスクトップアプリと連携する場合").font(.headline)
            Text("2. 下のボタンで、このブラウザから正規の1Passwordヘルパーに接続する準備をします。")
            Button("デスクトップ連携を準備") {
                do {
                    guard let path = NCChromiumProfileDirectory() else {throw OnePasswordIntegration.SetupError.profileUnavailable}
                    try OnePasswordIntegration.prepare(profile: URL(fileURLWithPath: path))
                    message = "準備しました。次に1Password側でブラウザを追加し、拡張機能を再読み込みしてください。"
                } catch {message = error.localizedDescription}
            }
            Text("3. 1Passwordを解除し、設定 → ブラウザ → ブラウザを追加 で、Applications内の署名済みneuraOSを選んでください。")
            Text("ブラウザの信頼登録とアカウントの認証はご自身で行ってください。ポップアップは専用ウィンドウから開けます。")
                .foregroundStyle(.secondary)
            Link("1Password公式の追加ブラウザ手順", destination: URL(string: "https://support.1password.com/additional-browsers/")!)
            if let message {Text(message).font(.callout).textSelection(.enabled)}
            HStack {Spacer(); Button("閉じる") {dismiss()}.keyboardShortcut(.cancelAction)}
        }.padding(24).frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}
