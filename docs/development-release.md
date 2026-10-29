# 開発・配布フロー

今回のリリース範囲はnative runtimeの性能改善と一般拡張・署名基盤。1Password実用化はユーザー判断で[Issue #134](https://github.com/oaktics/neuraOS/issues/134)へ保留し、専用設定導線を範囲から外す。保存・自動入力の受入未完了を今回のrelease blockerにはしない。一般拡張・署名・更新の回帰検証を維持する。最終比較は[性能資料](performance.md)、正式CI・公開結果は統合PRとGitHub Releasesを参照する。

1. `staging`を起点にneuraOSでworktreeを作成し、機能ブランチで変更・commitする。
2. GitHubサイドバーからPush → `staging`向けにPR作成。PR本文に変更内容と確認結果を書く。
3. CI `native-development / macos` とレビューを確認して`staging`へマージする。この段階ではリリースしない。
4. 複数の変更をまとめて動作確認したら、`staging` → `main` のリリースPRを作成する。`native-release / build` がApple Silicon向けのアプリ・配布パッケージをビルドし、パッケージ試験まで実行する。PRでは公開しない。
5. 確認後、リリースPRを**merge commit**で`main`へマージする。`native-release`がマージ後のソースを再検証し、成功したときだけGitHub Release `native-N` を公開する。Intel向けのビルド・配布は廃止。
6. native版同士はneuraOSメニュー → **アップデートを確認…** → **更新して再起動**。build62以前からの初回native移行は下記の専用手順を使う。

## ブランチ設定

GitHubのdefault branchは`staging`にする。neuraOSのPR作成画面はリポジトリのdefault branchを初期値に使うため、通常のPRは`staging`向けになる。リリースPRだけマージ先を`main`へ変更する。既存PRのマージ先は自動変更されないので、機能PRは個別に`staging`へ変更する。

リポジトリ管理者はrulesetでPR経由の変更と必須チェックを設定する。`staging`は`macos`、`main`は`build`を必須にする。どちらも最新のマージ先に対するチェック成功を要求し、管理者にも適用する。レビュー承認数は0とし、単独開発でもPR経由で変更できるようにする。ワークフローファイルだけでは直接pushやチェック前のマージを禁止できない。

長期運用する`staging` → `main`はsquash/rebaseせずmerge commitで履歴をつなぐ。リリース後は`main` → `staging`の同期PRをマージして履歴を揃える。緊急修正を`main`へ入れた場合も、同じように`staging`へ戻す。

## 通常CIと配布検証

- `staging`向け機能PRでは型チェック、Daemon等のテスト、更新処理のテスト、Swiftテスト、アプリの配布ビルド・パッケージ作成・同梱Daemonのsmoke試験を行う。週次・手動の通常CIも同じフル検証を行う。
- `staging`へのpushではmacOSで型チェック・Daemon等のテスト・更新処理のテストだけを行う。PTY統合テストをアプリと同じOSで検証する。Swift・配布パッケージの再検証は省略する。
- `main`向けPRでは`native-release`だけが動き、上記のフル検証にChromiumのsmoke試験を加える。マージ後の`main`では公開対象コミットを証明書付きでビルド・検証し、公証後のZIPを配布する。PRでは公開用ZIPの圧縮・転送を省略する。
- 機能ブランチのpushではCIを起動せず、PR作成・更新で実行する。`staging`へのマージ後は統合されたソースを軽量検証する。`main`へのpushはリリース側で検証する。
- ルートのMarkdown、`docs/`、PRテンプレート、Issueテンプレートだけの変更は、軽量な変更判定と必須チェックの完了だけを行う。macOS検証・成果物作成・Release公開を省略する。その他の場所にあるMarkdown（テストfixture等）は検証対象。mainのpushは直前のpushではなく最後に公開したReleaseとの差分で判定し、待機中のコード変更がドキュメントpushで置き換わっても未公開コードを配布する。初回Releaseは必ず検証・公開する。週次・手動実行は変更内容によらず検証する。
- 必須チェック`macos`と`build`は結果集約用のUbuntuジョブ。変更判定の失敗や必要な検証の失敗・キャンセルを成功として扱わない。ワークフロー自体をpath filterで省略しないため、ドキュメントPRでも必須チェックがPendingのまま残らない。
- 同じPR／ブランチの通常CIと、同じリリースPRの配布検証は、新しい更新が来たら古い実行をキャンセルする。公開処理を含む`main`のリリースは、実行中の1件をキャンセルせず完了させる。待機は最新の1件だけを保持し、さらに更新が来た場合は古い待機分を置き換える。すべての中間コミットを個別配布する保証はなく、まとめて最新の変更を配布する運用とする。
- pnpm、CEF SDK、Swiftの`.build`をキャッシュする。SwiftキャッシュはOS・CPU・Xcode/Swift/SDK・依存lockfile・CEFバージョンを分離し、同じ条件の過去のコンパイル結果を再利用する。ソース変更の判定と再ビルドはSwiftPMが行い、テストは毎回実行する。DebugテストとReleaseビルドの検証は維持する。
- ZIPは既に圧縮済みのためartifact転送時の再圧縮を省く。配布ZIPとcrash symbolsのActions artifactは1日保持とし、不要な長期保存を減らす。公開済みGitHub ReleaseのZIPは引き続き取得できる。
- 手動の通常CIは任意のブランチで実行できる。手動リリースは`main`を指定する。`staging`等を選んだ場合はビルド・公開ともスキップする。

## 配布と初回導入

新規導入ではGitHub Releasesの`neuraOS-darwin-arm64.zip`（Apple Silicon専用）を展開し、`~/Applications/neuraOS.app`へ置く。初回起動時は同梱native helperがLaunchAgentを確認する。既存LaunchAgentにrunning PIDがあれば、旧Node版や別パスのnative版でも温存する。停止中・未登録の場合だけ再登録する。新bundleを別場所から開くだけでは稼働サービスを置換しない。移行は明示的なupdater applyまたはservice installで行い、その前に作業を保存する。既存Node版からの移行は、アプリだけを手動上書きして完了とせず、以下のnative updaterでアプリとLaunchAgentを一緒に移行する。

Runtimeは`bin/neura-native-core`（Rust daemon／PTY／SQLite／provider／MCP）と`bin/neura-updater`（Swift更新helper）の2実行ファイルだけで構成する。これはRuntimeディレクトリの構成であり、Swift UI・CEF framework/helper・Sleep serviceを含むアプリ全体が2プロセスだけという意味ではない。neuraOSの配布RuntimeにNode.js・tsx・node_modulesは含めない。更新にXcode・pnpm・ソースチェックアウトは不要。Codex／Claude／Git／GitHub CLIなどの開発CLIは引き続き各自の環境を使う。

公開リポジトリはGitHub APIとHTTPSから直接更新する。非公開リポジトリは`gh auth login --hostname github.com`済みのGitHub CLIが必要。認証情報をアプリへコピー・保存しない。公開／非公開の設定自体はこの変更では変更しない。

公開用ビルドはDeveloper ID Application署名・Appleの公証・チケット添付・Gatekeeper検証を必須とする。資格情報が未設定、署名失敗、公証がAccepted以外の場合は公開しない。設定手順とローカル開発時のKeychain許可については[macOS署名と公証](macos-signing.md)を参照。通常のPR検証は明示的なad-hoc署名で実行し、署名用の秘密鍵を渡さない。

## build62以前からの初回native移行

build62の旧updaterは新アーカイブにも`Runtime/bin/node`を要求し、適用時にNode・tsx・`service.ts`を使う。このため**旧「更新して再起動」だけではNodeを含まないnative版へ直接移行できない**。新しい署名・公証済み公開成果物のhelperを直接使う。以下は利用者が移行を決め、全作業を保存した後の手順であり、開発検証中の通常installed app／daemonには実行しない。

1. GitHub Releasesから公開済みの`neuraOS-darwin-arm64.zip`を取得し、Downloads等に展開する。現在の`~/Applications/neuraOS.app`はまだ上書きしない。
2. 展開した新アプリ内のhelperを絶対パスで指定し、更新対象tagを確認する。

   ```sh
   HELPER="$HOME/Downloads/neuraOS.app/Contents/Resources/Runtime/bin/neura-updater"
   "$HELPER" check
   ```

3. `check`が返した`native-N`と、現在の**旧neuraOS UIアプリ**のPID（daemonやTerminalのPIDではない、1より大きい値）を指定する。以下の`native-N`と`OLD_APP_PID`は実値へ置き換える。

   ```sh
   "$HELPER" prepare native-N OLD_APP_PID
   ```

   helperは公式Releaseを再ダウンロードするため、展開済みbundleだけのoffline installではない。アーカイブはファイルへダウンロードし、SHA-256を1 MiBずつ読み込んで検証するため、CEFを含むZIP全体をメモリへ読み込まない。最新tag一致・署名・Gatekeeper・bundle ID・build番号・native Runtimeも検証する。`{"ready":true}`は準備完了であり移行完了ではない。prepare中に先に旧UIを終了せず、この応答後60秒以内に通常終了する。終了しなければappを置き換える前に中止する。`prepare`がstageへhelperをコピーして`apply`を自動起動するので、`apply`を手動で重ねて実行しない。

   旧UIが起動不能または既に完全終了している場合は、短命のshellの終了を待つ次の形を使う（`native-N`は実値へ置き換える）。旧UIがまだ動いている状態では使わない。sudoは不要。

   ```sh
   /bin/sh -c '"$1" prepare "$2" "$$"' sh "$HELPER" native-N
   ```

4. helperが旧appを`~/Applications/neuraOS.app.previous`へ退避し、新appを配置する。旧LaunchAgent plistも`~/Library/Application Support/neuraOS/Updates/previous-launch-agent.plist`へ保存する。Daemonを停止・再登録し、認証付きHTTP health確認後に新appを開く。healthはHTTP 200に加え`runtime: "rust"`、有効なUUIDの`daemonInstanceId`、置換前と異なるinstanceであることを要求し、旧Nodeの200応答や旧native instanceを成功と誤認しない。既存PTY／エージェントは終了する。
5. 新appのbuild番号、native daemonへの接続、履歴復元を確認する。これをRelease公開・署名公証・fixture成功とは別のinstalled-app受入として記録する。

登録やhealth確認の失敗時は、helperが旧appと旧plistを戻して旧daemonの再登録を試みる。復元の成否はサービス状態と`Updates/last-error.txt`を確認する。旧プロセスの実行継続やDBの巻き戻しは保証しない。復元自体に失敗した場合は`.previous`と保存plistを保持し、進行中のhelperがないことを確認してから調査・復旧する。再実行は既存backupを置き換えるため、原因を確認せず連打しない。

2026-10-29の隔離fixtureでは、旧Node Runtimeを模したappからの移行成功と、health失敗時の旧app・plist復元を含むSwift updater 12 testsが通過した（packaging担当の記録: `/tmp/neura-native-migration-tests.log`）。`launchctl`／`open`／healthはmockで、公開Releaseのdownloadから実ユーザー環境へのapplyを実証したものではない。Developer ID署名済み検証bundle自体は未公証で、そのhelperの直接起動も不正PIDを変更前に拒否するところまでの確認である。通常installed app／daemonはこの検証で変更していない。

追加の`854cc25`では稼働サービス温存・新native instance判定・ファイルdownload／stream hashを実装し、Swift updater 17 testsが成功した（`/tmp/neura-native-review-fixes-tests-final.log`）。続く`5014291`で`pnpm dev`も`service ensure`へ変更し、稼働サービス温存を含む18 testsが成功した（`/tmp/neura-native-dev-preservation-tests.log`）。これらは隔離fixtureの結果であり、最新の署名済み候補からの実サービス移行は別の未実施項目である。

## 更新の保証範囲

- 更新番号はreleaseワークフローの`github.run_number`。アプリへ同じ番号を埋め込み、現在より新しい番号だけを案内する。
- Apple Silicon向けの成果物をDraft ReleaseへアップロードしてからLatestとして公開する。ビルド・試験失敗時は公開しない。
- アーキテクチャ、GitHub assetのSHA-256、署名整合性・Gatekeeperの受理、bundle ID、ビルド番号を検証してから適用する。SHA-256はGitHub APIの認証されたメタデータとの一致確認であり、更新プログラム自体は署名者のTeam IDを固定していない。公開時のDeveloper ID署名・公証・Gatekeeper検証とは別の保証範囲である。
- 明示的な更新操作後にアプリを終了し、ユーザー所有の`~/Applications/neuraOS.app`を入れ替え、Daemonを再登録する。実行中のPTY／エージェントは終了する。保存済みプロジェクト・履歴は既存のDeveloperディレクトリを引き継ぐ。
- 旧アプリは`~/Applications/neuraOS.app.previous`へ保存する。起動確認失敗時はアプリとLaunchAgent設定を戻す。更新前の実行プロセスそのものやDBの巻き戻しはしない。将来のDB変更は旧版互換の追加方式とし、破壊的な変更には別途バックアップ・復元設計が必要。
- 更新失敗は`~/Library/Application Support/neuraOS/Updates/last-error.txt`へ記録する。インストーラーが強制終了した場合は、更新処理が動いていないことを確認して同フォルダの`install.lock`を削除して再試行する。

## ローカル検証

### 追加料金なしで待ち時間を減らす選択肢

2026-10-29時点の比較。直近の[release実行](https://github.com/oaktics/neuraOS/actions/runs/40811010465)は約8分37秒で、Swiftテスト2分20秒、Releaseビルド1分49秒、ZIP圧縮34秒・artifact upload11秒だった。公証導入前の実測であり、公証待ち時間は含まない。

PR #130では、[キャッシュ作成時](https://github.com/oaktics/neuraOS/actions/runs/40830977478)8分37秒から[キャッシュ利用時](https://github.com/oaktics/neuraOS/actions/runs/40832029850)5分46秒へ約33%短縮した。Swiftテストは2分12秒→1分4秒、Releaseビルドは1分59秒→57秒。Swiftソースに変更がない場合の実測であり、ソース変更時や公証待ちを含む配布全体の時間を保証するものではない。

| 方式 | 追加料金なしの範囲 | neuraOSへの適合 |
| --- | --- | --- |
| GitHub標準runner＋キャッシュ | 公開リポジトリの標準runner実行は無料 | 現構成を維持できる。まずCEF・Swiftキャッシュと不要なZIP処理を削減 |
| Xcode Cloud | Developer Programに月25 compute hoursが付属 | Xcode project/workspace・共有scheme・archive設定が必要。現状のSwiftPM＋独自パッケージ処理からの移行工数がある |
| CircleCI Free | 月30,000 credits。M4 Pro Mediumは200 credits/分なので計算上約150分/月（他用途の消費前） | 現在の頻度では枠が小さい。移すだけで高速になる実測根拠はない |
| 自前Mac runner | GitHubの実行料金は無料。所有Macの電力・保守は別 | キャッシュを保持できるが、常時稼働と他作業との負荷分離が必要。署名鍵のある普段のユーザーで外部PRを自動実行しない |

GitHub以外への移行はまだ行っていない。まず標準runnerでキャッシュ後の時間を比較し、必要ならXcode Cloudまたは専用Macで同じコミットを試す。公証はApple側の処理なので、CI提供元を変更してもその待ち時間は残る。

出典: [GitHub billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、[self-hosted runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)、[Xcode Cloud](https://developer.apple.com/xcode-cloud/)、[Xcode Cloudの構成要件](https://developer.apple.com/documentation/xcode/Setting-up-your-project-to-use-Xcode-Cloud)、[CircleCI Free](https://circleci.com/pricing/)、[CircleCI単価](https://circleci.com/pricing/price-list/)。無料の実行枠とartifact/cache容量は別条件。Actions artifactの保持を短くし、cacheを10 GBの標準枠内で運用する。

### コマンド

```sh
pnpm install --frozen-lockfile
cargo test --manifest-path crates/native-core/Cargo.toml
cargo build --release --locked --manifest-path crates/native-core/Cargo.toml
NEURA_NATIVE_DAEMON="$PWD/crates/native-core/target/release/neura-native-core" \
  node --test tests/native-rust/protocol.test.mjs tests/native-rust/migration.test.mjs \
  tests/native/provider-native-mcp.test.mjs tests/native/provider-daemon-parallel.test.mjs
pnpm typecheck
pnpm test
node --test tests/release/*.test.mjs
pnpm test:macos
pnpm build
node scripts/native/release/package.mjs
node scripts/native/release/smoke.mjs
```

`pnpm daemon`はRust daemonを起動する。比較用の旧TypeScript daemonは`pnpm daemon:legacy`に限定する。`pnpm service`は開発用Node wrapperからnative helperへ転送する。`pnpm dev`はbuild後に`service ensure`を使い、旧Node版・別パスのnative版も含め稼働中のDaemonとPTYを温存する。停止中・未登録の場合だけ開発用native版を登録する。稼働サービスの置換は明示的な`pnpm service install`またはupdater applyで行う。`restart`・`stop`もPTYを終了する明示操作なので、先に作業を保存する。

パッケージ試験はRuntime全体をリポジトリ外の一時ディレクトリに移し、一時データと空きポートで同梱のネイティブDaemon／SQLite／PTYを実行する。ソースチェックアウトや開発環境の`node_modules`に依存しないことを確認する。Node.jsはこの試験を起動する開発ツールとして使用する。Daemon部分だけの再検証は`node scripts/native/release/runtime-smoke.mjs`で実行できる。ユーザーのLaunchAgentと実行中のターミナルには触れない。実際の配布更新は、初回Release公開後に別のMacユーザー等の検証環境で行う。

## native統合の検証checkpoint（2026-10-29）

[統合PR #133](https://github.com/oaktics/neuraOS/pull/133)の`a61effc`までの実装を照合した時点。以下はローカル検証で、正式CI・署名公証済みrelease・実installed appでの移行成功を示すものではない。正式なCI結果はPRのchecks、公開版の署名・公証とtagは[GitHub Releases](https://github.com/oaktics/neuraOS/releases/latest)で確認する。

| 検証 | 確認した結果 | 証跡／範囲 |
| --- | --- | --- |
| Rust core | library 85成功、integration 5成功 | `/tmp/neura-review-final-rust.log`。子プロセス内の部分再実行を重複加算しない |
| 最適化版の公開protocol／移行／provider／ownership | 28成功、失敗0、skip 0 | `/tmp/neura-review-final-public.log`。HTTP／MCP、Node→Rust→Node移行、fake CLI各10/20/32、共有予約、attach前crash、lifetime lockを含む。実モデル負荷や速度比較ではない |
| 実daemon間データ移行 | Node→Rust→Node、1成功 | [保存証拠](architecture-evidence/legacy-native-data-migration-2026-10-29.json)、`/tmp/neura-root-migration-final.log`。同一の隔離DBでUnicode PTY/cursor、設定、通知、pending/reports/exact ACK、復旧状態、operation結果を確認。実LaunchAgent／installed appの更新ではない |
| native ProviderService並列起動 | Claude／Codexのfake CLI各10/20/32、全7成功 | [保存証拠](architecture-evidence/native-provider-daemon-parallel-2026-10-29.json)、`/tmp/neura-root-provider-daemon-parallel.log`。全段階で指定数の同時active、登録、入力、turn event、exit、UI stream再接続/cursor replayを確認。終了後残存プロセス0 |
| plist署名正規化のrelease回帰 | 13成功 | `/tmp/neura-root-plist-release-tests.log`。正式CI／公証とは別 |
| 実Claude読取専用MCP | Claude 2.1.312、exit 0、`MCP_READONLY_OK` | `/tmp/neura-real-claude-5w7j1tvp/evidence.json`。実CLIがnative MCPの`task_list`を1回実行し、workspace／terminal context一致を確認。変更操作・並列モデル負荷の実証ではない |
| 実Codex接続 | 対象integration 1成功 | `/tmp/neura-root-real-codex.log`。root実行報告では実CLIのApp Server起動・`thread/loaded/list`・close/reapのみ。model turn実行や相互委任の実証ではない。テスト自体の実CLI分岐は`NEURA_TEST_CODEX_PATH`指定時のみ |
| Swift UI | 142成功 | `/tmp/neura-root-swift-all.log` |
| Swift updater | 18成功 | `/tmp/neura-root-updater18-tests.log`。実LaunchAgent適用とは別 |
| legacy互換テスト | 全体165件中164成功、1失敗後に対象1件再試験成功 | `/tmp/neura-root-legacy-contract-tests.log`、`/tmp/neura-root-client-capabilities-retest.log`。Swift source列挙漏れの修正後の対象再試験であり、全体を再実行して165成功したとは記さない |

Git／workspace runner／providerの終了処理は、reapしないexit通知→`tree.stop()`→`wait`の順でleaderの識別をcleanupまで保持する。短命leaderとrestricted子を含む正常終了・失敗・timeout・cancelのcleanupを上記Rust試験で確認した。これは任意の子孫の完全回収保証ではなく、[macOSの所有追跡境界](native-process-ownership.md)は維持する。

実Claudeの確認範囲は上記の読取専用MCP実行。実CodexはApp Server接続のみでmodel turnを実行していない。fake CLI並列試験は実モデル負荷や性能比較ではなく、provider App Server自体の切断・再接続も未検証。最適化版の旧新idle/load比較は同一PC・FULL/WAL・1/5/10/20/32 PTYで各2回実施し、[測定結果と限界](performance.md#optimized-comparison-2026-10-29)に記録した。1PasswordはConnected表示後もaccount-readyへ至らず、popup／通常拡張tabのロゴ停止と公式overview HTTP 500が観測された。fixture CSPは修正済みだが、保存・自動入力は未成功。原因未確定のまま[Issue #134](https://github.com/oaktics/neuraOS/issues/134)へ保留し、今回のrelease完了条件から分離する。正式CIと署名・公証はGitHubの実行結果、公開tagはReleasesで確認する。実installed appの更新・rollback成功はローカルfixtureやCIの成功とは区別する。

## Chromium browser

Browser pages use CEF (Chromium), with one page per existing workspace tab, alongside Terminal/Codex. Popup pages join that same tab bar. There is no nested browser tab bar. Extensions share the Chromium profile. Chrome-style management windows provide extension installation and toolbar popups. See [browser extensions](browser-extensions.md) and [deferred 1Password investigation](1password-browser.md).

`pnpm build` and `pnpm test:macos` prepare the pinned CEF SDK from `scripts/native/chromium/version.json`. Direct `swift build/test` users must first run `node scripts/native/chromium/prepare.mjs`. Downloads and extracted SDKs are shared across worktrees in `~/Library/Caches/neuraOS/cef/<architecture>-<archive checksum>/` (override with `NEURA_CEF_CACHE_DIR`). Each worktree keeps an ignored `apps/macos/.cef/sdk` symlink; generated helpers stay local. Completed cache entries are published atomically, so concurrent builds never consume a partial extraction. Simultaneous first-time preparations may download independently; subsequent preparations reuse the SDK. Old worktree-local SDK directories are replaced with links on preparation. Direct Swift commands still require preparation once per worktree. The archive checksum is verified before extraction; updating Chromium requires updating both architecture entries in the manifest and rerunning the packaged smoke test. Chromium is bundled with the application, so security updates require a new neuraOS release.

The bridge loads CEF dynamically, embeds native child views, and keeps the renderer/GPU sandbox enabled. Helpers initialize the sandbox before loading CEF. Browser content has no daemon token or native terminal API bridge. CEF persists cookies/storage in `<NeuraDataDirectory>/Chromium` (default `~/Library/Application Support/neuraOS/Chromium`), separate from the former WebKit store. Existing browser URLs remain; websites require signing in again after migration. Independent development apps should use a separate `NEURA_DEV_DATA_DIR` to avoid profile locks.

After `pnpm build`, run `node scripts/native/chromium/smoke.mjs`. It launches the actual bundled executable against a loopback fixture with a temporary profile and verifies Chromium rendering, back/forward navigation, popup opener preservation, cookies/local storage across two launches, and clean shutdown. It does not authenticate to Gmail or access the normal profile. This is separate from verifying an authenticated Gmail session and from installing a release.
