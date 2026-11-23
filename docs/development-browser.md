# 開発用ブラウザ

内蔵ブラウザは localhost プレビュー、コンソール、GitHub などの開発用途向けです。
新規タブは `about:blank` から始まり、保存済みタブの URL は復元します。
アドレス欄・コマンドバーからの検索は引き続き使えます。

neuraOS を既定ブラウザにする設定、http/https の URL handler 登録、他アプリからの
リンク受信は削除しました。「外部のブラウザで開く」は残り、旧 neuraOS が既定でも
neuraOS の bundle ID を除外して Safari（なければ他の登録済みブラウザ）へ渡します。
外部ブラウザが見つからない場合は neuraOS に戻さず何もしません。
以前 neuraOS を既定にした Mac では、システム設定 → デスクトップと Dock →
デフォルトの Web ブラウザで外部ブラウザを選び直してください。既定設定は自動変更しません。

## 保存済み履歴

アプリ独自の閲覧履歴記録とコマンドバーの履歴候補は削除しました。
既存ファイルは自動削除せず、読み書きもしません。残る場所は
`~/Library/Application Support/neuraOS/Developer/browser-history.json` です。
`NeuraDataDirectory` を指定したビルドでは、そのディレクトリ直下です。
この独自履歴に UserDefaults 保存はありません。
Chromium プロファイルの履歴、セッションの戻る／進む、タブ復元用 `browser.*`、
favicon キャッシュは別データで、この変更では削除しません。

## 維持する機能と保留した旧経路

開発者ツール、再読み込み／ハードリロード、ページ内検索、ズーム、分割表示、
OAuth ポップアップ、favicon、ダウンロード、MCP、URL コピーを維持します。
プロジェクトのピン・サイドバー固定タブの機能は変更しません。

1Password のインストール・有効化・デスクトップ連携設定・Chrome のパズルボタンは
維持します。[拡張機能](browser-extensions.md)と[1Password](1password-browser.md)を参照。
通常タブでのストアインストールを実証していないため、拡張管理とストアは従来の
Chrome-style ウィンドウを使います。

旧 SwiftUI 拡張ツールバー wrapper と戻る／進む／再読み込みボタンは削除しました。
旧アドレス・ピンを含む fallback header は PR #226 の変更行と重なるため残しています。
`ExtensionSmokeAccessory` が使う `ExtensionToolbarView`、拡張 popover と
ChromiumBridge の Alloy (`chromeTab=NO`) は到達可能なスモーク経路として残します。
`extensions-smoke.mjs` / `extension-origin-smoke.mjs` がこの経路を使います。
ポップアップ生成は親の `chromeTab` を引き継ぐので変更しません。
