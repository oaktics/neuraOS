# 開発・配布フロー

1. `staging`を起点にneuraOSでworktreeを作成し、機能ブランチで変更・commitする。
2. GitHubサイドバーからPush → `staging`向けにPR作成。PR本文に変更内容と確認結果を書く。
3. CI `native-development / macos` とレビューを確認して`staging`へマージする。この段階ではリリースしない。
4. 複数の変更をまとめて動作確認したら、`staging` → `main` のリリースPRを作成する。`native-release / build` がApple Silicon向けのアプリ・配布パッケージをビルドし、パッケージ試験まで実行する。PRでは公開しない。
5. 確認後、リリースPRを**merge commit**で`main`へマージする。`native-release`がマージ後のソースを再検証し、成功したときだけGitHub Release `native-N` を公開する。Intel向けのビルド・配布は廃止。
6. neuraOSメニュー → **アップデートを確認…** → **更新して再起動**。

## ブランチ設定

GitHubのdefault branchは`staging`にする。neuraOSのPR作成画面はリポジトリのdefault branchを初期値に使うため、通常のPRは`staging`向けになる。リリースPRだけマージ先を`main`へ変更する。既存PRのマージ先は自動変更されないので、機能PRは個別に`staging`へ変更する。

リポジトリ管理者はrulesetでPR経由の変更と必須チェックを設定する。`staging`は`macos`、`main`は`build`を必須にする。どちらも最新のマージ先に対するチェック成功を要求し、管理者にも適用する。レビュー承認数は0とし、単独開発でもPR経由で変更できるようにする。ワークフローファイルだけでは直接pushやチェック前のマージを禁止できない。

長期運用する`staging` → `main`はsquash/rebaseせずmerge commitで履歴をつなぐ。リリース後は`main` → `staging`の同期PRをマージして履歴を揃える。緊急修正を`main`へ入れた場合も、同じように`staging`へ戻す。

## 通常CIと配布検証

- `staging`向け機能PRでは型チェック、Daemon等のテスト、更新処理のテスト、Swiftテスト、アプリの配布ビルド・パッケージ作成・同梱Daemonのsmoke試験を行う。週次・手動の通常CIも同じフル検証を行う。
- `staging`へのpushではmacOSで型チェック・Daemon等のテスト・更新処理のテストだけを行う。PTY統合テストをアプリと同じOSで検証する。Swift・配布パッケージの再検証は省略する。
- `main`向けPRでは`native-release`だけが動き、上記のフル検証にChromiumのsmoke試験とZIP作成を加える。マージ後の`main`では公開対象コミットを再検証して配布する。
- 機能ブランチのpushではCIを起動せず、PR作成・更新で実行する。`staging`へのマージ後は統合されたソースを軽量検証する。`main`へのpushはリリース側で検証する。
- ルートのMarkdown、`docs/`、PRテンプレート、Issueテンプレートだけの変更は、軽量な変更判定と必須チェックの完了だけを行う。macOS検証・成果物作成・Release公開を省略する。その他の場所にあるMarkdown（テストfixture等）は検証対象。mainのpushは直前のpushではなく最後に公開したReleaseとの差分で判定し、待機中のコード変更がドキュメントpushで置き換わっても未公開コードを配布する。初回Releaseは必ず検証・公開する。週次・手動実行は変更内容によらず検証する。
- 必須チェック`macos`と`build`は結果集約用のUbuntuジョブ。変更判定の失敗や必要な検証の失敗・キャンセルを成功として扱わない。ワークフロー自体をpath filterで省略しないため、ドキュメントPRでも必須チェックがPendingのまま残らない。
- 同じPR／ブランチの通常CIと、同じリリースPRの配布検証は、新しい更新が来たら古い実行をキャンセルする。公開処理を含む`main`のリリースは、実行中の1件をキャンセルせず完了させる。待機は最新の1件だけを保持し、さらに更新が来た場合は古い待機分を置き換える。すべての中間コミットを個別配布する保証はなく、まとめて最新の変更を配布する運用とする。
- pnpmのダウンロードキャッシュを再利用する。Swiftテストはネイティブ側のコンパイルも行うため、通常CIでもコンパイル時間は必要。
- 手動の通常CIは任意のブランチで実行できる。手動リリースは`main`を指定する。`staging`等を選んだ場合はビルド・公開ともスキップする。

## 配布と初回導入

GitHub Releasesの`neuraOS-darwin-arm64.zip`（Apple Silicon専用）を展開し、`~/Applications/neuraOS.app`へ置く。初回起動時、Daemonが未登録なら同梱版をLaunchAgentに登録する。既存Daemonが稼働中の場合は勝手に再起動しない。ソース版からの初回移行は、更新機能入りのソース版を一度ビルドして「更新して再起動」を使うか、作業を保存して旧Daemonを`pnpm service stop`で止めてから配布版を開く。

Node.js、tsx、Daemon、依存パッケージとネイティブPTYをアプリに同梱する。更新にXcode・pnpm・ソースチェックアウトは不要。Codex／Claude／Gitなどの開発CLIは引き続き各自の環境を使う。

公開リポジトリはGitHub APIとHTTPSから直接更新する。非公開リポジトリは`gh auth login --hostname github.com`済みのGitHub CLIが必要。認証情報をアプリへコピー・保存しない。公開／非公開の設定自体はこの変更では変更しない。

現在は個人利用向けad-hoc署名で、Apple Developer ID署名・公証は未導入。ダウンロードしたアプリの初回起動がGatekeeperで止まった場合は、出所を確認してmacOSの「システム設定 → プライバシーとセキュリティ」から許可する。一般配布で警告なしに起動するにはDeveloper ID証明書と公証用資格情報の設定が別途必要。

## 更新の保証範囲

- 更新番号はreleaseワークフローの`github.run_number`。アプリへ同じ番号を埋め込み、現在より新しい番号だけを案内する。
- Apple Silicon向けの成果物をDraft ReleaseへアップロードしてからLatestとして公開する。ビルド・試験失敗時は公開しない。
- アーキテクチャ、GitHub assetのSHA-256、署名整合性、bundle ID、ビルド番号を検証してから適用する。SHA-256はGitHub APIの認証されたメタデータとの一致確認であり、Developer IDによる作者証明ではない。
- 明示的な更新操作後にアプリを終了し、ユーザー所有の`~/Applications/neuraOS.app`を入れ替え、Daemonを再登録する。実行中のPTY／エージェントは終了する。保存済みプロジェクト・履歴は既存のDeveloperディレクトリを引き継ぐ。
- 旧アプリは`~/Applications/neuraOS.app.previous`へ保存する。起動確認失敗時はアプリとLaunchAgent設定を戻す。更新前の実行プロセスそのものやDBの巻き戻しはしない。将来のDB変更は旧版互換の追加方式とし、破壊的な変更には別途バックアップ・復元設計が必要。
- 更新失敗は`~/Library/Application Support/neuraOS/Updates/last-error.txt`へ記録する。インストーラーが強制終了した場合は、更新処理が動いていないことを確認して同フォルダの`install.lock`を削除して再試行する。

## ローカル検証

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
node --test tests/release/*.test.mjs
pnpm test:macos
pnpm build
node scripts/native/release/package.mjs
node scripts/native/release/smoke.mjs
```

パッケージ試験は一時データと空きポートで同梱Node／Daemon／SQLite／PTYを実行する。ユーザーのLaunchAgentと実行中のターミナルには触れない。実際の配布更新は、初回Release公開後に別のMacユーザー等の検証環境で行う。

## Chromium browser

Browser pages use CEF (Chromium), with one page per existing workspace tab, alongside Terminal/Codex. Popup pages join that same tab bar. There is no nested browser tab bar. Extensions are not included.

`pnpm build` and `pnpm test:macos` prepare the pinned CEF SDK from `scripts/native/chromium/version.json`. Direct `swift build/test` users must first run `node scripts/native/chromium/prepare.mjs`. Downloads and extracted SDKs are ignored under `apps/macos/.cef/`. The archive checksum is verified before extraction; updating Chromium requires updating both architecture entries in the manifest and rerunning the packaged smoke test. Chromium is bundled with the application, so security updates require a new neuraOS release.

The bridge loads CEF dynamically, embeds native child views, and keeps the renderer/GPU sandbox enabled. Helpers initialize the sandbox before loading CEF. Browser content has no daemon token or native terminal API bridge. CEF persists cookies/storage in `<NeuraDataDirectory>/Chromium` (default `~/Library/Application Support/neuraOS/Chromium`), separate from the former WebKit store. Existing browser URLs remain; websites require signing in again after migration. Independent development apps should use a separate `NEURA_DEV_DATA_DIR` to avoid profile locks.

After `pnpm build`, run `node scripts/native/chromium/smoke.mjs`. It launches the actual bundled executable against a loopback fixture with a temporary profile and verifies Chromium rendering, back/forward navigation, popup opener preservation, cookies/local storage across two launches, and clean shutdown. It does not authenticate to Gmail or access the normal profile. This is separate from verifying an authenticated Gmail session and from installing a release.
