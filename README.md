# neuraOS

macOS向けの、自分用のAI開発ワークスペース。SwiftUIのネイティブUIと、独立したローカルDaemonで構成します。ターミナル表示には[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0)のAppKitビューを使用し、PTYはDaemon側に置きます。

**0.2.0 開発版。** 旧版の「副社長・部長・社員」「タスク生成・記憶・クラウド同期」は新しい製品の対象から外しました。まずリポジトリ、worktree、対話CLI、ファイル、差分、プレビューを一つの画面で扱います。

## 起動

Node.js 24.13以降の24系、pnpm 11.9、XcodeのSwiftツールチェーン・Metal Toolchain、Gitが必要です。UIの対象はmacOS 14以降（実機確認環境はmacOS 26）。Codex／Claude Codeは各公式CLIをインストール・ログインして使います。

```sh
pnpm install --frozen-lockfile
# Metal Toolchainが未導入の場合のみ
xcodebuild -downloadComponent MetalToolchain
pnpm dev
```

`pnpm dev`はDaemonが未登録ならユーザーのLaunchAgentとして登録し、SwiftUIアプリをビルドして開きます。既に動いているDaemonは再起動しません。

生成先：`apps/macos/dist/neuraOS.app`

単独操作：

```sh
pnpm build
pnpm service status
pnpm service install
pnpm service stop
pnpm service restart
```

`install`と`restart`は既存DaemonのPTYを終了します。作業中は実行しないでください。アプリのウィンドウを閉じる／アプリを終了するだけならPTYは継続します。Daemon自身の再起動やログアウト・PC停止後は履歴を復元し、中断として表示します。生きていたプロセスを復元したとは表示しません。

このビルドは個人開発用のad-hoc署名です。DaemonはこのチェックアウトとNode環境を参照します。単体配布用のバンドル・公証・自動更新は未実装です。

## 最初の作業

1. `⌘O`で作業するフォルダを開く。Gitリポジトリでなくても利用できます。
2. Gitリポジトリの場合は`⌘N`でプロジェクトと作成元（既定は`HEAD`）を選び、専用ブランチとworktreeを作成。名前の入力は不要です。Codex・Claude Codeの会話名が付くと、左サイドバーのworktree表示名に自動反映されます（通常3秒程度）。会話名がない間は仮名を表示し、ブランチ名とフォルダのパスは変更しません。
3. Codex／Claude Codeのタブから対話CLIをfull accessで起動。ログイン、会話再開はCLI自身の画面で行います。
4. ターミナル、ファイル、変更一覧、ブラウザのタブで作業。
5. アプリを終了してもDaemonは継続。再度開くと同じPTYへ接続し、出力を復元。

worktreeやタブを切り替えても、一度表示したターミナルの画面・スクロール位置・出力の読み取り位置を保持します。非表示中も低頻度で出力を取り込み、戻った際に先頭から再生し直しません。アプリを終了した場合は、従来どおり保存ログから復元します。

会話名の定期取得は稼働中のCLIがあるworktreeだけで行います。CLI終了時は最後に一度取得し、その後は保存済みの表示名を使います。

通常のフォルダでは、そのフォルダでCLI、ターミナル、ファイル編集、ブラウザを使えます。Gitの初期化は行いません。worktree作成と差分表示はGitリポジトリのみで利用できます。後から自分でGitを初期化した場合は、同じフォルダをもう一度開くとGit機能が有効になります。

「メイン」は元のフォルダ／リポジトリです。専用作業はworktree上で行います。worktreeはファイル変更を分離するもので、セキュリティ境界ではありません。

- 同じworktreeでCodex、Claude Code、シェルをそれぞれ1つ開けます。別worktreeでも並行して起動できます。
- 新規起動・会話再開ともに、Codexは`--sandbox danger-full-access --ask-for-approval never`、Claude Codeは`--permission-mode bypassPermissions`を指定します。ファイル操作やコマンド実行の都度の権限承認なしで動作します。CLIや組織の管理ポリシーによる制限は引き続き適用されます。
- 起動済みの端末へ再接続しても権限は変わりません。起動設定の変更は、更新済みDaemonから新しくCLIを起動したときに適用されます。
- CLIのログイン情報をneuraOSが読み取ってコピーする方式は使いません。CLIが通常のユーザー環境で自身の設定と認証を利用します。
- ファイル編集は1MB以下のUTF-8テキスト。保存時のハッシュ照合で外部更新を検知します。未保存の編集はUI端末へ自動退避し、通常の終了・再起動後に復元します。強制終了時は直近約0.5秒分が失われる可能性があります。
- Git操作のうちworktree作成・状態取得・差分表示をUIから利用できます。GitHubへのpush・PR作成・PRマージは「GitHub」タブから利用できます。commit、ローカルのmerge、worktree削除はターミナルで行います。
- ブラウザは独立したWKWebView。端末操作用のブリッジやDaemonの資格情報を持ちません。現時点ではUI端末からURLへ接続します。

## GitHub 連携

GitHub CLI（`gh`）をインストールし、ターミナルで一度ログインします。DaemonはCLI自身の認証を利用し、トークンをコピーして保存しません。

```sh
brew install gh
gh auth login --hostname github.com
gh auth setup-git
```

Gitリポジトリの「GitHub」タブでは、`origin`と現在のブランチからPRを取得します。対応するOpen PRを優先し、なければ直近のClosed/Merged PRを表示します。表示中は30秒ごとに更新し、手動更新もできます。

アプリはDaemonの応答に含まれる `features: ["github"]` を確認してからGitHub機能を有効にします。`pnpm dev`で旧Daemonを起動したままアプリだけ更新した場合、GitHubタブは無効になり、保存済みのGitHub画面には更新案内を表示します。他の機能と既存PTYは継続して利用できます。作業を保存してDaemonを更新・再起動すると、アプリ側で対応を再検出します。

- **Push**：表示されたコミットとブランチを確認して送信。未コミットのファイルは含めません。force push・ブランチ削除は行いません。
- **PR作成**：タイトル、説明、マージ先、Draftを指定。既定はDraftで、作成前のPushも選択できます。
- **コメント確認**：通常のコメント、レビュー、コード行へのコメントを全ページ取得。CI、レビュー判定、未解決スレッド数とGitHubへのリンクも表示します。
- **マージ**：リポジトリで許可された方式を選択し、PR・マージ先・コミットを確認。Daemonが最新状態を再取得し、Open、非Draft、`CLEAN`、未解決スレッドなし、ローカルとPRのコミット一致を確認したうえで、GitHubへ期待するhead SHAを指定します。GitHubの保護ルールはそのまま適用されます。

初期対応はgithub.comの`origin`内で完結するPRです（HTTPS / SSH）。forkから別リポジトリへのPRとGitHub Enterpriseは対象外です。コメントの投稿・返信、スレッド解決、Draft解除は「GitHubで開く」から行います。マージキューや自動マージの設定もGitHub側で行ってください。

GitHubに接続できない場合は「PRなし」と扱わずエラーを表示し、古い表示からの操作を無効にします。操作の応答が不明な場合は状態を更新し、GitHub上で結果を確認してください。GitHubの通信中もターミナル入力とファイル保存は独立して利用できます。

## 構成

```text
apps/macos/           SwiftUI / AppKit / WebKitクライアント
apps/daemon/          Node.js / TypeScript / node-pty / SQLite
scripts/native/       ビルドとLaunchAgent管理
tests/native/         Daemonの統合・復旧試験
```

UIはGit・プロセス・プロジェクトファイルを直接操作しません。認証付きの`/v1` HTTP APIからDaemonへ要求します。端末出力と状態イベントには順序を持たせ、再接続時に再取得できます。通信契約は`apps/daemon/src/contracts.ts`、Swift側のモデルは`apps/macos/Sources/NeuraOS/Models.swift`です。

現在は`127.0.0.1:4318`限定で待ち受けます。UIとDaemonの接続に使うローカルトークンは権限0600のファイル、データディレクトリは0700です。ブラウザOrigin付き要求は拒否します。

保存先：`~/Library/Application Support/neuraOS/Developer/`

- `developer.sqlite`：プロジェクト、worktree、端末、イベント、出力、操作ID。
- `worktrees/`：Daemonが作成するGit作業領域。
- `daemon-token`：同一ユーザーのネイティブUI向け接続資格情報。
- `daemon.log` / `daemon-error.log`：サービスログ。

端末の出力はローカルに保存されます。現在は自動保持期限・ローテーションなしです。通常のユーザー権限のCLIを起動する開発ツールであり、未信頼コードを隔離するサービスではありません。

## 将来の別PC・スマホ操作

UI依存のXPCオブジェクトやローカルファイルURLを通信契約に使わず、Daemon所有のID、バージョン付きAPI、操作ID、イベント／端末出力カーソルを使用します。ターミナルの入力者には15秒の占有期間を設け、別のクライアントとの同時入力を拒否します。

遠隔接続はまだ有効化していません。次段階で端末ペアリング・失効、TLSとVPNまたは中継、入力権の明示移譲、開発サーバーのポート転送を追加します。クラウドDBはローカル利用の前提にしません。Windows／Androidには別のUIが必要ですが、DaemonのAPIは共有できます。

## 検証

```sh
pnpm typecheck
pnpm test
pnpm build
```

自動試験は独立した一時GitリポジトリとSQLiteで、認証、Origin拒否、重複操作、並行worktree、ファイルの競合・境界検査、PTYの入力・履歴、再接続、Daemon再起動時の中断表示を検証します。実際のモデルによる開発完了とは別の試験です。

## 旧版の保全

旧実装は`apps/desktop`、`apps/runner`、`apps/cloud-api`と既存の`packages`に残しています。新Daemonは旧タスクエンジンをimportしません。旧データも削除しません。旧READMEは`docs/legacy/development-v0.1.md`。旧コマンドには`legacy:`を付けています。

以前のv1仕様と受け入れ基準は旧構想の記録です。現在の製品方針・起動手順はこのREADMEを正とします。
