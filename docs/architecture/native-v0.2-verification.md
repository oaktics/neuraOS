# neuraOS 0.2 実装・検証記録

確認日：2026-10-21。macOS実機、開発用ad-hoc署名ビルド。

追記：通常フォルダ対応。Git未初期化のフォルダをネイティブの選択画面から開き、ファイル一覧・内容表示とGit専用UIの非表示を実機確認。通常フォルダの保存・PTY・再起動復元・後からのGit移行を含む自動試験は3件成功、型チェックと再ビルド成功。既存データのGit属性省略は従来のリポジトリとして扱う。

## 今回の範囲

SwiftUI / AppKit UIとNode.js Daemonを別プロセスに分離した、個人用の開発ワークスペース。旧タスク・組織・記憶エンジンは新しい実行経路に含めない。DaemonがGit、worktree、PTY、ファイル、SQLiteを所有し、UIは認証付きv1 APIを使う。

ターミナルはSwiftTermで表示し、Codex / Claude Codeの対話CLIをそのまま起動する。独自のAI会話・権限承認エンジンは実装していない。ブラウザは独立したWKWebView。

## 自動確認

- `pnpm typecheck`：成功。
- `pnpm test`：2件成功。実Git・SQLite・PTYを使った統合試験と、CLI起動引数の検査。
- `pnpm build`：Swiftリリースビルドとアプリバンドル生成成功。
- 統合試験：認証、Origin拒否、操作IDの重複排除、並行worktree、ファイル保存の競合検知、パス境界、PTY入力・履歴、入力所有権、Daemon再起動後の中断表示。

## ネイティブUI実機確認

ユーザーデータと分離した一時リポジトリ、別ポートのDaemon、別bundle IDのQAアプリで実施。

- サイドバーで別worktreeへ切り替えられる。
- 新しい作業ダイアログからworktreeを作成し、選択状態になる。
- 日本語テキストを編集・保存し、Git変更一覧と差分に反映される。
- 未保存のREADME編集がアプリ終了・再起動後に復元される。保存操作前のリポジトリ実体は変更されない。
- 組み込みブラウザでローカル開発ページを表示できる。
- シェルの出力が表示される。UI終了後も遅延コマンドが完了し、ファイルが生成される。再起動後、同じPTYに再接続できる。
- Codex CLIから検証ファイルを作成。`native-agent-check.txt`の内容が`native-codex-ok`の1行であることを別途読み直して確認。CLIの完了応答も出力履歴で確認。
- Claude Codeは通常の対話画面まで起動し、manual modeを表示。Claudeによるモデル実行・ファイル変更は今回未検証。

QAのCLI・Daemonは検証後に停止。通常利用用のLaunchAgent `app.neuraos.daemon` と `apps/macos/dist/neuraOS.app` を起動し、初期画面と接続を確認した。

## 保全と未実装

旧ソースと旧データは保持。旧Runnerは停止し、LaunchAgentのplistはユーザーデータのLegacyディレクトリへ退避した。

別PC・スマホ用クライアント、遠隔端末ペアリング、TLS・中継、ポート転送、公証済み単体配布、自動更新、LSP、UIからのcommit/merge/push/worktree削除は未実装。現時点はローカルの開発版であり、旧v1構想の完成版ではない。遠隔拡張はDaemonのID・API・イベントカーソルを境界として追加する。
