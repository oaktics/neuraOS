# Codexの作業をまとめて監督する

neuraOSから起動したCodexは、他のCodexや「Codexの作業一覧」から会話を確認し、指示を送れます。先にworktreeで作業を始め、後からメインでCodexを起動しても同じ一覧を使えます。親から起動されたセッションだけを対象にする仕組みではありません。

## 使い方

1. worktreeで通常どおりCodexを起動します。
2. メインでもCodexを開き、「他のworktreeのCodexを確認して、必要な修正を指示して」と依頼します。
3. CodexにはneuraOSのMCPが自動で渡されます。作業一覧を取得し、会話を読み、追加の指示や方向修正を送れます。
4. 新しい分担は「別worktreeでこの作業を進めて」と依頼します。worktree作成、Codex起動、最初の指示まで実行できます。
5. タブ追加メニューの「Codexの作業一覧」から、人間も同じ会話を確認できます。通常の指示は作業終了後に順番に送り、「実行中の作業へすぐ反映」は現在のターンに追加します。

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
| `task_send` | 順番待ち／実行中への方向修正 |
| `task_interrupt` | 指定ターンの中断、未送信指示と監視の解除 |
| `task_respond` | 正確なrequest IDに対する回答 |
| `task_watch` | 次のターン終了時に監督側へ一回だけ報告 |
| `task_wait` | revision以降の状態変化を待つ |

変更操作にはoperation IDが必要です。同じIDの再試行は保存された結果を返します。worktree作成と起動は別段階で、起動失敗時もworktreeとそのIDを返します。自動起動設定との二重起動は避けます。方向修正と中断にはexpected turn IDを要求します。

監視報告はユーザー指示に偽装せず `toolOutput` として送信します。監視解除と報告のキュー追加を同じ保存操作で行い、再起動後の二重配信を防ぎます。自己監視と循環する監視は拒否します。

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
