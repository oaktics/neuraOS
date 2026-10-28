# Codex・Claudeの作業をまとめて監督する

neuraOSから起動したCodexは、他のCodexや「エージェントの作業一覧」から会話を確認し、指示を送れます。先にworktreeで作業を始め、後からメインでCodexを起動しても同じ一覧を使えます。親から起動されたセッションだけを対象にする仕組みではありません。

## 使い方

1. worktreeで通常どおりCodexを起動します。
2. メインでもCodexを開き、「他のworktreeのCodexを確認して、必要な修正を指示して」と依頼します。
3. CodexにはneuraOSのMCPが自動で渡されます。作業一覧を取得し、会話を読み、追加の指示や方向修正を送れます。
4. 新しい分担は「別worktreeでこの作業を進めて」と依頼します。worktree作成、Codex起動、最初の指示まで実行できます。
5. ホームの「エージェントの作業一覧」から、人間も同じ会話を確認できます。通常の指示は作業終了後に順番に送り、「実行中の作業へすぐ反映」は現在のターンに追加します。

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
| `workspace_create` | agentを起動せず登録worktreeを作成 |
| `task_spawn` | worktree作成とproviderを選んだagent起動・初期指示 |
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

## Claude Codeと相互委任する

Claude Codeは従来の対話ターミナル画面を維持し、SessionStart/StopフックでCodexと同じ作業一覧に登録されます。`task_spawn`/`task_start`の`provider`に`codex`または`claude`を指定できます。省略時はプロジェクトの既定委任providerを使い、再開時は元のproviderを優先します。呼び出し元の現在のtaskを監督として記録し、初回指示の実行前に子のwatchを追加します。既存のwatchは維持します。

プロジェクトの「既定のAI」で会話と委任のproviderを別々に設定できます。未設定時は既存の自動起動設定に含まれるagentが1種類なら継承します。shellは除外し、両agentまたは未設定ならCodexです。既存プロジェクトの設定データを一括変更しません。

Claudeにはセッション限定のMCP、共有指示、フック、`--dangerously-load-development-channels server:neuraos`を渡します。Claude標準の起動確認は維持し、他のMCPとユーザー設定を変更しません。Channelsはresearch previewです。CLI・ログインアカウント・組織設定の対応が必要で、非対応CLIは更新理由を表示します。作業一覧では接続待ちと端末を確認でき、CLIが出すアカウント・組織制限の理由もターミナルに残ります。MCP接続だけでは実指示を配送しません。nonce付きprobeをClaudeが専用channel_ackツールで返すまで指示を保持します。60秒で未確認なら利用不可として表示します。確認probeの完了は子の作業完了として報告しません。

Claudeへの指示はChannelsで現在の応答完了後に配送します。実行中へのsteerは非対応でUIも無効化します。質問・承認はClaudeのターミナルから回答します。待機中のキー操作だけでは取消完了と見なさず指示を保持します（Claudeの質問画面はCtrl-Cだけでは終了しない場合があり、画面の取消操作が必要です）。実際のライフサイクル通知後に次の指示を配送します。報告は`kind=reports`の通知であり、実行指示へ変換しません。送信前に通知済みを記録し、不明な送信結果を自動再送しません。報告は`task_ack`まで保持します。Channelsのpollは通常のdaemon認証に加え、daemon内でのみ発行する端末別のランダム資格を要求し、他端末の資格やmaster bearerだけでは通知を消費できません。

compactは実行中ターンを保持します。clear/resumeは現在の会話を切り替え、旧会話の指示を新会話へ配送しません。同じ会話の重複起動、異なるworkspace/providerでの再開を拒否します。停止した会話は中断として保存され、停止後の自動配送は行いません。Claude履歴はbyteカーソルで最大2MBずつ非同期取得し、tool call/resultを含む実行証跡を表示します。巨大な単一記録は省略を明記し、原本のtranscriptは保持します。

共通ルールは`session-instructions.ts`で管理します。独立実装はneuraOS MCPで登録された別worktree/agentへ自律委任し、親はwatch/read/ack、差分・テストの確認、統合、許可されたrelease、safe cleanupまで継続します。小調査に不要なworktreeや委任は作りません。ユーザー指示・上位制約を優先し、権限を拡張しません。自分だけの隔離作業には`workspace_create`を使えます。

2026-10-28にClaude Code 2.1.312と実Codexを、別ポート・別dataのneuraOS daemonから起動して検証しました。Claude監督→Codex子完了→ChannelsでClaude再開→ack、およびCodex監督→Claude子完了→tool outputでCodex再開→ackを確認しています。通常のdaemonとインストール済みアプリは変更・停止していません。

仕様参照: [Channels reference](https://code.claude.com/docs/en/channels-reference)、[Hooks](https://code.claude.com/docs/en/hooks)。

## 報告と実行指示の分離

長時間作業中の監督へ進捗を `task_send` で送り続けると、次ターン用の実行指示キュー（32件）を埋めてしまいます。進捗・完了には `task_report` を使用します。報告は `agent.reports` の専用受信箱に保存し、実行指示の枠を消費しません。監督は作業中でも `task_read`、`task_list`、`task_wait` の返す `reports` を読み、受領したIDだけを `task_ack` で確認済みにします。受領確認は作業内容の承認・検証完了を意味しません。読み取りだけでは報告を消さず、通信失敗時も再取得できます。

受信箱は32件、手動報告本文は16,384文字までです。手動報告が満杯なら `agent_reports_full` を返し、未読報告を捨てません。監督のack後、新しいoperation IDで再送してください（同じoperation IDは元の失敗結果を返します）。実行指示への迂回送信はしません。watch報告はworkerごとに最新完了状態へ集約し、更新回数を記録します。更新時に新しい報告IDを発行するため、古いIDへのackは新しい報告を消しません。途中の会話・検証証跡は `task_read` で確認します。受信箱満杯で新しいworkerの報告を追加できない場合はwatchを維持し、ackで空きができた時に配信します。配信待ちwatch（最大32件）にもworkerごとの最新完了スナップショットを1件保持し、workerが次ターンを始めても完了証跡を失いません。

待機中の監督へは未通知報告をまとめて `toolOutput` で通知します。通知開始前に通知済みと記録し、報告はackまで受信箱に残します。監督がackせずターンを終えても、同じ報告IDで無限に再開しません。通知の送信結果が不明な場合も自動再送せず、受信箱から確認します。実行中の監督にはターンを追加せず、read/wait/ackで消費させます。未実行指示がある場合は従来どおり指示を先に送ります。

既存の `task_send` の意味と32件上限は維持します。旧 `report:true` のwatch報告だけを受信箱へ段階移行し、32件を超えた旧報告はackで空くまで旧領域に保持します。通常の旧 `task_send` は文面から報告と推測せず、未読指示として保持します。`task_ack` は実行指示を一切削除しません。起動済み旧セッションには新しいルールが自動注入されないため、更新後の起動・再開または明示的な運用切替が必要です。この変更で稼働中daemonのキュー削除や再起動は行いません。

## 完了したworktreeのcleanup

監督は必要な検証、依頼された範囲のマージ、不要になったworktreeの安全な削除までを別々に確認します。ユーザーの保持指示を優先し、未完了作業・他人の変更は破棄しません。`workspace_delete` は既存 `workspace.delete` に `stopTerminals:true`、`discardChanges:false` とcleanup検証条件を渡します。呼び出し元workspaceは起動時の環境から指定し、自分自身とrootを拒否します。

`expectedHead` と `mergedPR` が必要です。originのGitHub上でPRがMERGEDであり、そのPRのhead SHAが現在のHEADと一致することを確認するため、squash mergeでも対応します。未pushの追加コミット、マージ後の変更、未統合のPRは削除できません。PRを使わない調査用worktreeなど確認材料のない場合は自動削除せず、保持して報告します。実行中・回答待ち・失敗・未実行指示・未受領報告・監視のあるtaskも拒否します。停止前後にHEADとdirty/未追跡/ignoredを再確認し、従来の停止バリアとGitの安全な削除を利用します。コミット済みブランチは保持します。Claude・旧方式Codex・シェルなどで作業終了を確認できない実行中端末も拒否し、人間による確認・停止まで保持します。旧UI/APIの削除動作は変更しません。

`node_modules`、`.build`、`.cef` などもignoredなら削除を拒否します。まず中身・用途・生成元を確認し、再生成可能と確認できた生成物だけを対象を絞って除去してください。名前だけで再生成可能とは判断しません。`.env`、秘密情報、未知のファイル、保持を求められたデータは残し、cleanupの阻害理由として報告します。MCPに汎用force/discardや名前だけに基づく再帰削除を公開しません。

MCPは削除の成功時とAPI失敗時にworkspaceの登録状態を読み戻し、成功時は `verifiedAbsent`、失敗時は `workspacePresent` を返します。読み戻し自体ができなければ確認済みとは扱いません。監督も `workspace_list` で結果を確認し、ブロックされた場合は削除未完了と報告します。
