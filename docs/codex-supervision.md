# Codexの作業をまとめて監督する

neuraOSから起動したCodexは、他のCodexや「Codexの作業一覧」から会話を確認し、指示を送れます。先にworktreeで作業を始め、後からメインでCodexを起動しても同じ一覧を使えます。親から起動されたセッションだけを対象にする仕組みではありません。

## 使い方

1. worktreeで通常どおりCodexを起動します。
2. メインでもCodexを開き、「他のworktreeのCodexを確認して、必要な修正を指示して」と依頼します。
3. CodexにはneuraOSのMCPが自動で渡されます。作業一覧を取得し、会話を読み、追加の指示や方向修正を送れます。
4. 新しい分担は「別worktreeでこの作業を進めて」と依頼します。worktree作成、Codex起動、最初の指示まで実行できます。
5. ホームの「Codexの作業一覧」から、人間も同じ会話を確認できます。通常の指示は作業終了後に順番に送り、「実行中の作業へすぐ反映」は現在のターンに追加します。

監督するCodexが `task_watch` を登録すると、対象の次のターン終了時に報告を受け取り、待機中でも自動で再開します。監督側が作業中なら報告は順番待ちになります。監視は一回限りで、継続するときは再登録します。`task_wait` は変化を最大25秒待つための読み取りツールです。

応答が終わったことと、依頼が検証を含めて完了したことは別です。監督側は会話、差分、テスト結果を確認して判断します。PR作成・マージ・デプロイは別の操作です。

## 対応範囲

- Codex CLI 0.165.0で実機検証。`--remote`、UnixソケットのApp Server、`thread/inject_items`、会話ページング、`turn/steer`、`turn/start`のtool outputに対応するCLIが必要です。
- 対応CLIでneuraOSから新しく起動したCodex、および「履歴から再開」で開いた会話が対象です。履歴から再開した会話は、作業フォルダが一致するものを登録します。`/new`で作った会話も履歴が保存された後に検出します。
- 古いCLIは従来のターミナル起動を維持し、監督対象にはなりません。起動済みの旧方式CLIや、別アプリが所有する実行中のCodexへ、後付けで接続を奪うことはしません。停止後、更新済みのneuraOSから履歴を再開すると対象になります。
- アプリのウィンドウを閉じてもDaemonとCodexは継続します。ターミナル停止、worktree削除、Daemon再起動では対象のCodexも停止します。再起動後の登録は「中断」で復元し、自動で実行中に戻しません。
- 中断した会話は作業一覧の「再開」から開けます。停止中でも保存済みの会話を読めます。送信済みか不明な指示は自動再送しません。まだ送信していない指示は保存し、会話を再開して次の指示を送ったときに順に処理します。

## 実装

Daemonがターミナルごとに専用の `codex app-server --listen unix://…` を起動します。Unixソケットは権限0700の一時ディレクトリ内に置き、TUIとDaemonの制御クライアントが同じApp Serverに接続します。既存のユーザー認証・設定を利用し、既存CLIと同じfull accessで実行します。App Serverの所有プロセスはDaemonとのパイプ切断を検知し、Daemonの異常終了時にも子プロセス群を停止します。

Codexの会話IDを作業IDとして、`agents`テーブルにworkspace・terminal・状態・ターンID・未送信の指示・監視対象を保存します。起動順や親子関係に依存しません。CLIの画面テキストから会話IDや完了を推測しません。

新しい空の会話は説明用のdeveloper itemを `thread/inject_items` で保存してからTUIで再開します。会話を作っただけではモデルを実行しません。利用者の設定ファイルやグローバルMCP設定は書き換えず、そのApp Serverと会話だけにMCP設定を渡します。

| MCPツール | 用途 |
| --- | --- |
| `workspace_list` | プロジェクト・worktree・呼び出し元の作業領域 |
| `task_list` | 起動順に依存しない全セッションの一覧 |
| `task_read` | 会話のページ取得、状態、質問、送信待ちの確認 |
| `task_spawn` | worktree作成とCodex起動・初期指示 |
| `task_start` | 既存worktreeで起動、停止済みの会話を再開 |
| `task_send` | 実行指示の順番待ち／実行中への方向修正（進捗報告には使わない） |
| `task_report` | 進捗・完了を報告専用受信箱へ送信 |
| `task_ack` | 読んだ報告IDを受領確認（実行指示は削除しない） |
| `workspace_delete` | 検証・依頼済みマージ後の安全なworktree cleanup |
| `task_interrupt` | 指定ターンの中断、未送信指示と監視の解除 |
| `task_respond` | 正確なrequest IDに対する回答 |
| `task_watch` | 次のターン終了時に監督側へ一回だけ報告 |
| `task_wait` | revision以降の状態変化を待つ |

変更操作にはoperation IDが必要です。同じIDの再試行は保存された結果を返します。worktree作成と起動は別段階で、起動失敗時もworktreeとそのIDを返します。自動起動設定との二重起動は避けます。方向修正と中断にはexpected turn IDを要求します。

監視報告はユーザー指示に偽装せず `toolOutput` として送信します。監視解除と専用受信箱への報告追加を同じ保存操作で行い、再起動後の二重配信を防ぎます。自己監視と循環する監視は拒否します。

HTTP APIは既存の認証・Origin拒否・操作重複排除を共有します。MCPはloopbackのDaemonだけに接続し、トークンファイルを読みます。トークン値をプロンプトや起動引数に埋め込みません。会話、指示、回答は既存のローカルデータ保存範囲で扱います。

## 検証

通常の回帰テスト：

```sh
pnpm typecheck
pnpm test
pnpm test:macos
pnpm build
```

実モデルでの検証は明示的に実行します。ログイン済みアカウントを使用し、一時リポジトリ・worktree・別ポートのDaemonを作成して終了後に片付けます。通常のneuraOS Daemonを再起動しません。

```sh
NEURA_LIVE_CODEX_TEST=1 node --import tsx scripts/native/supervision-smoke.ts
```

この検証は、先に起動したworktreeのCodexを後から起動したメインがMCPで発見すること、指示の重複排除、子の応答終了後に待機中のメインがtool outputで自動再開すること、Daemon再起動後の履歴読み取りと同一会話の再開を実際のCodexで確認します。モデルの会話履歴はCodex側に保存されます。

仕様参照: [Codex App Server](https://learn.chatgpt.com/docs/app-server)

## Claude Codeからの利用と共通ルール

neuraOSから新規起動・履歴再開したClaude Codeにも、`--mcp-config` のインラインJSONで `neuraos` MCPを自動接続します。`--append-system-prompt` で使い方と共通作業ルールを渡します。CLIのhelpで両フラグを確認し、非対応なら更新を案内します。設定はその起動だけに適用され、`~/.claude.json`、ユーザー／プロジェクト設定、グローバルMCP登録は変更しません。他のMCP設定や既存の状態通知フックも維持します。組織のMCP制限は引き続き適用されます。既に起動中のClaudeへの後付け注入は行いません。

共通ルールは `session-instructions.ts` に集約し、専用Codex App Serverにも `-c developer_instructions=…` を渡してCLI内の新規会話を含めます。Codexの開始・再開・履歴選択後の発見と、Claudeの起動・再開に渡します。

- 作業開始時に `task_list` で既存作業を確認し、重複を避けて関連セッションを再利用します。
- 独立した変更はworktreeに隔離します。質問・単純調査に不要なworktreeは作らず、割り当て済みの作業領域は理由なく移動しません。
- 独立して並行できる作業は、委任が許され有用な場合に別セッションへ依頼します。親は `task_read`、`task_wait` と、利用可能なら `task_watch` を使い、差分・テスト・統合競合まで確認します。
- ユーザーの明示指示と上位制約を優先し、マージ・releaseは依頼された範囲だけ実施します。これはモデルへの作業方針であり、操作権限を拡張するものではありません。

ClaudeはMCPの呼び出し側として、既存のCodexを `task_list`／`task_read`／`task_send` などで操作できます。`task_spawn` と `task_start` が起動するのはCodexです。呼び出し元はworkspace IDとterminal IDで識別し、daemonの権限0600のトークンファイルから取得したBearerで認証します。トークン値を起動引数に含めません。認証は既存Codexと同じローカルdaemon単位であり、セッション別のアクセス制限ではありません。呼び出し元にCodex task IDが存在することは要求しません。

Claude自身は `agents` に登録されず、「Codexの作業一覧」や `task_read`／`task_send` の対象にはなりません。terminal IDをtask IDとして使わないでください。`parentTaskId` を指定する場合は登録済みCodexのIDが必要です。`task_watch` の報告先も登録済みCodexに限られ、Claudeのターン終了後の自動再開は未対応です。Claudeが監督する間は `task_read`／`task_wait` を利用します。

2026-10-28にClaude Code 2.1.312の `--help` と公式docsで互換性を確認しました。現行CLIには `-p` とstream-jsonによるプログラム制御、backgroundセッションの `--bg`／`agents`／`attach`／`logs`／`stop` もあります。ただし現在のneuraOSは対話PTYでClaudeを起動しており、これらを既存CodexRPCの代替として接続する実装はありません。Claude自身の双方向監督には別の制御アダプターと会話・ターン・承認・再開の対応付けが必要です。

回帰テストは実daemonのClaude起動引数（新規／再開、MCP、フック、共有指示、動的ポート、呼び出し元ID、トークン非露出）、非対応CLIの更新案内、Codexへの共有指示注入、およびstdio MCPの認証・操作を検証します。偽CLIによる引数検証と実モデルの接続確認は別の検証です。

仕様参照: [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)、[MCP](https://code.claude.com/docs/en/mcp)、[プログラムからの実行](https://code.claude.com/docs/en/headless)

実Claude Code 2.1.312でも、隔離した一時daemonへ同じ起動引数を渡し、`task_list` と `workspace_list` の成功、および一致するworkspace／terminal IDを確認しました（2026-10-28、printモードでの実モデル検証）。対話画面での `/mcp` 操作やClaudeからの変更系操作の実モデル検証は含みません。

Codex設定仕様: [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) の `developer_instructions`（セッション追加指示）。


## 報告と実行指示の分離

長時間作業中の監督へ進捗を `task_send` で送り続けると、次ターン用の実行指示キュー（32件）を埋めてしまいます。進捗・完了には `task_report` を使用します。報告は `agent.reports` の専用受信箱に保存し、実行指示の枠を消費しません。監督は作業中でも `task_read`、`task_list`、`task_wait` の返す `reports` を読み、受領したIDだけを `task_ack` で確認済みにします。受領確認は作業内容の承認・検証完了を意味しません。読み取りだけでは報告を消さず、通信失敗時も再取得できます。

受信箱は32件、手動報告本文は16,384文字までです。手動報告が満杯なら `agent_reports_full` を返し、未読報告を捨てません。監督のack後、新しいoperation IDで再送してください（同じoperation IDは元の失敗結果を返します）。実行指示への迂回送信はしません。watch報告はworkerごとに最新完了状態へ集約し、更新回数を記録します。更新時に新しい報告IDを発行するため、古いIDへのackは新しい報告を消しません。途中の会話・検証証跡は `task_read` で確認します。受信箱満杯で新しいworkerの報告を追加できない場合はwatchを維持し、ackで空きができた時に配信します。

待機中の監督へは未通知報告をまとめて `toolOutput` で通知します。通知開始前に通知済みと記録し、報告はackまで受信箱に残します。監督がackせずターンを終えても、同じ報告IDで無限に再開しません。通知の送信結果が不明な場合も自動再送せず、受信箱から確認します。実行中の監督にはターンを追加せず、read/wait/ackで消費させます。未実行指示がある場合は従来どおり指示を先に送ります。

既存の `task_send` の意味と32件上限は維持します。旧 `report:true` のwatch報告だけを受信箱へ段階移行し、32件を超えた旧報告はackで空くまで旧領域に保持します。通常の旧 `task_send` は文面から報告と推測せず、未読指示として保持します。`task_ack` は実行指示を一切削除しません。起動済み旧セッションには新しいルールが自動注入されないため、更新後の起動・再開または明示的な運用切替が必要です。この変更で稼働中daemonのキュー削除や再起動は行いません。

## 完了したworktreeのcleanup

監督は必要な検証、依頼された範囲のマージ、不要になったworktreeの安全な削除までを別々に確認します。ユーザーの保持指示を優先し、未完了作業・他人の変更は破棄しません。`workspace_delete` は既存 `workspace.delete` に `stopTerminals:true`、`discardChanges:false` とcleanup検証条件を渡します。呼び出し元workspaceは起動時の環境から指定し、自分自身とrootを拒否します。

`expectedHead` と `mergedPR` が必要です。originのGitHub上でPRがMERGEDであり、そのPRのhead SHAが現在のHEADと一致することを確認するため、squash mergeでも対応します。未pushの追加コミット、マージ後の変更、未統合のPRは削除できません。PRを使わない調査用worktreeなど確認材料のない場合は自動削除せず、保持して報告します。実行中・回答待ち・失敗・未実行指示・未受領報告・監視のあるtaskも拒否します。停止前後にHEADとdirty/未追跡/ignoredを再確認し、従来の停止バリアとGitの安全な削除を利用します。コミット済みブランチは保持します。Claude・旧方式Codex・シェルなどで作業終了を確認できない実行中端末も拒否し、人間による確認・停止まで保持します。旧UI/APIの削除動作は変更しません。

`node_modules`、`.build`、`.cef` などもignoredなら削除を拒否します。まず中身・用途・生成元を確認し、再生成可能と確認できた生成物だけを対象を絞って除去してください。名前だけで再生成可能とは判断しません。`.env`、秘密情報、未知のファイル、保持を求められたデータは残し、cleanupの阻害理由として報告します。MCPに汎用force/discardや名前だけに基づく再帰削除を公開しません。

MCPは削除の成功時とAPI失敗時にworkspaceの登録状態を読み戻し、成功時は `verifiedAbsent`、失敗時は `workspacePresent` を返します。読み戻し自体ができなければ確認済みとは扱いません。監督も `workspace_list` で結果を確認し、ブロックされた場合は削除未完了と報告します。
