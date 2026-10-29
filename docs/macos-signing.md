# macOS署名と公証

## 証明書

GitHub Releasesで配布するZIPには **Developer ID Application** を使用する。`.pkg`を配布しないためDeveloper ID Installerは不要。Xcode → Settings → Apple Accounts → 対象チーム → Manage Certificatesから作成し、次で秘密鍵付きの有効な証明書を確認する。

```sh
security find-identity -v -p codesigning
```

秘密鍵、`.p12`、公証用パスワードをリポジトリやチャットへ保存しない。

## ローカル開発とChromium Safe Storage

`pnpm build` / `pnpm dev`は有効なDeveloper ID Application証明書が1つだけなら自動選択する。複数ある場合は、固定した証明書名をシェル設定で指定する。

```sh
export NEURA_SIGN_IDENTITY='Developer ID Application: Kiichi Sato (3BNMLRRV2K)'
pnpm build
```

証明書が見つからない場合はビルドを止める。署名に必要なlogin Keychainへのアクセスを許可すること。sandboxからの`security find-identity`は実際に存在する証明書を表示できない場合がある。

ad-hoc署名のdesignated requirementはビルドに依存する。証明書による署名と固定bundle IDに切り替えることで、再ビルドのたびにKeychainから別アプリとして認識されることを防ぐ。Apple DevelopmentとDeveloper IDではrequirementが異なるため、日常的に同じプロファイルを使うアプリの署名種別・Team ID・bundle IDを切り替えない。

既存ad-hoc版からの移行時は、Chromium Safe Storageへのアクセスを一度許可する必要がある場合がある。OSが表示する確認で対象アプリを確かめて許可する。Keychain項目やブラウザプロファイルを削除したり、全アプリのアクセスを許可したりして解決しない。Keychainのロックなど、署名以外の原因による確認まで抑制するものではない。

別worktreeでも同じ署名identityとbundle IDを使う。別アプリを同時起動する場合は`NEURA_DEV_DATA_DIR`等でプロファイルとDaemonの接続先を分ける。署名やプロファイルを毎回ランダムにしない。

使い捨てのCI・隔離したテストだけは`NEURA_SIGN_IDENTITY=-`で従来のad-hoc署名を明示できる。普段使うアプリをこの設定でビルドしない。

## 署名する範囲

証明書を使う場合は、実ファイルのMach-Oヘッダーを調べて同梱コードを列挙する。CEF内のライブラリ、Helper、Node、native addon、Sleep serviceを内側から署名し、最後にアプリを署名する。symlinkをたどって同じコードを再署名しない。署名にはHardened Runtimeとsecure timestampを使用する。`--deep`は検証時だけ使う。

Renderer/GPUとNode等のJIT実行プロセスに`allow-jit`を付ける。CEFの`browser_subprocess_path`が指す汎用のNeuraOS HelperもRendererを兼ねるため対象にする。署名済みアプリと同梱ライブラリは同じTeam IDを使い、library validationを維持する。Sleep serviceにはJITやlibrary validation無効化の例外を付けない。

## GitHub Actions

通常PRとmain向けPRは秘密鍵を使わずad-hoc版を検証する。mainのpushまたはmainでの手動releaseでは単体テスト後に専用の一時Keychainへ証明書を取り込み、最初から証明書付きの配布版を作り、CEF・パッケージのsmokeを実行する。公証は最大30分待ち、Acceptedを確認してstaple・検証後に最終ZIPを作成する。失敗時にad-hoc版を公開するフォールバックはない。

RepositoryのActions secretsに以下を設定する。

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Developer ID Application証明書と秘密鍵を含む、パスワード付きp12のBase64 |
| `APPLE_CERTIFICATE_PASSWORD` | p12を書き出した際のパスワード |
| `APPLE_ID` | 公証するApple Account |
| `APPLE_TEAM_ID` | 証明書のTeam ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | Apple Accountで発行した公証用app-specific password |

Actions variable `APPLE_SIGN_IDENTITY`には証明書の完全な名前を指定する。未指定なら一時Keychainの検索リストから一意のDeveloper ID証明書を選ぶ。アカウントの通常のログインパスワードは使わない。

このリポジトリの個人チーム用には`bash scripts/native/signing/setup-credentials.sh`で対話設定できる。先にKeychain Accessの「自分の証明書」でDeveloper ID Applicationを秘密鍵付きのパスワード保護されたp12へ書き出し、Apple AccountでApp用パスワードを作成する。スクリプトはパスワード入力を非表示にし、公証認証をAppleで検証してlogin Keychainの`neura-local`へ保存後、`oaktics/neuraOS`のActions secretsへ標準入力経由で登録する。ファイル・パスワードをチャットへ送る必要はない。

専用Keychainは秘密鍵の利用をcodesign向けに設定し、処理終了時には検索リストを元に戻して削除する。証明書とパスワードはartifactやログに出さない。秘密鍵を渡すジョブではmainに取り込んだコードが実行されるため、mainの保護とPRレビューを維持する。

## ローカル公証と確認

以下の最初のコマンドは対話入力。資格情報をコマンド行や履歴に書かず、Keychain profileへ保存する。

```sh
xcrun notarytool store-credentials neura-local
node scripts/native/release/package.mjs
NEURA_NOTARY_PROFILE=neura-local node scripts/native/signing/notarize.mjs
```

公証がタイムアウトした場合、Apple側の処理が中断されたとは限らない。表示されたsubmission IDを使い`xcrun notarytool info <ID> --keychain-profile neura-local`で状態を確認する。ZIPにはstapleできないため、公証チケットを付けたappからZIPを作り直す。

署名・公証の成功とKeychainの実機確認は別々に行う。証明書付きのビルドを起動して一度許可し、コードを変更して再ビルド・再起動してもSafe Storageの確認が繰り返されず、ログイン状態が保たれることを確認する。普段のアプリでの確認には作業保存後の再起動が必要。

参考: [Apple: Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[CEF: Code Signing](https://github.com/chromiumembedded/cef/blob/master/docs/code_signing.md)、[Apple: Notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
