# アップデート配信（Sparkle + Cloudflare）

neuraOSのアプリ更新は[Sparkle 2](https://sparkle-project.org/)で行う。配布物はCloudflare R2に置き、Worker（`infra/update-worker`）が配信する。GitHubリポジトリの公開・非公開に関係なく更新が届き、利用者のMacに`gh`のログインは不要。

## 全体の流れ

```
main へマージ
  └─ release.yml (macOS)  ビルド → Developer ID署名 → 公証 → ZIP
       └─ publish (Ubuntu)
            ├─ appcast.mjs   ZIPをEd25519で署名し appcast.xml を更新
            ├─ R2へ ZIP → appcast.xml の順でアップロード
            ├─ 古いZIPを削除（appcastに残すのは最新10件）
            └─ GitHub Release native-N（移行期間のみ）

アプリ (Sparkle)
  ├─ 1日1回＋メニュー「アップデートを確認…」で appcast.xml を取得
  ├─ ZIPを取得 → EdDSA署名とDeveloper ID（Team ID一致）を検証
  ├─ 「インストールして再起動」で .app をその場で置換して再起動
  └─ 起動時に neura-updater reconcile が Daemon を新しいバージョンへ切替
```

| 配信URL | 内容 | キャッシュ |
| --- | --- | --- |
| `/appcast.xml` | Sparkleのフィード | `no-cache`（毎回再検証） |
| `/releases/neuraOS-<build>-darwin-arm64.zip` | 公証済みアプリ | 1年・immutable（同名で上書きしない） |

それ以外のパスは404。認証はかけていない。バイナリは署名・公証済みで、ソースは含まない。

## 安全性

- **EdDSA署名**: appcastの各項目にZIPのEd25519署名が入る。アプリに埋め込んだ公開鍵（`SUPublicEDKey`）で検証するため、WorkerやR2が改ざんされても偽の更新は入らない。
- **コード署名**: Sparkleは新しいアプリが現在と同じDeveloper IDで署名されていることも確認する。旧updaterで未対応だったTeam IDの固定はこれで担保される。
- **鍵の不一致を公開前に検出**: `appcast.mjs`は秘密鍵から導いた公開鍵が`SPARKLE_PUBLIC_KEY`と一致しなければ失敗する。不一致の更新を出すと、インストール済みの全アプリがそれ以降の更新を拒否するため。
- **自動インストールはしない**: 確認は自動だが、ダウンロードとインストールは利用者の操作が必要（`SUAllowsAutomaticUpdates=false`）。更新するとDaemonが再起動し、PTYが止まるため。
- 開発版・fixture・PRのビルドにはフィードURLと公開鍵を入れないので、Sparkleは起動しない。

## Daemonの切り替え

Sparkleは`.app`を同じ場所で置換する。LaunchAgentは同じパスを指したままで、旧Daemonは置換前の実行ファイルで動き続ける。再起動後、アプリは`neura-updater reconcile <build>`を実行する。

| 状態 | 動作 |
| --- | --- |
| サービスが停止中・未登録 | 同梱Daemonを登録（初回起動と同じ） |
| LaunchAgentが別のアプリ／旧Node版を指している | 触らない（`foreign`） |
| 稼働中Daemonの`daemonBuild`がアプリと同じ | 何もしない |
| ビルドが異なり、直前に「インストールして再起動」が選ばれた | Daemonを再登録し、新instanceが同じbuild番号を返すまで確認 |
| ビルドが異なり、承認がない（終了時インストールなど） | ダイアログで確認。「後で」なら次回起動時に再度確認 |

承認はアプリが再起動直前に書く`~/Library/Application Support/neuraOS/Updates/relaunch-approved`で受け渡す。15分以内のものだけ有効で、読んだら消す。Daemonは`/v1/state`の`daemonBuild`でビルド番号（`NEURA_BUILD_NUMBER`）を返す。これを返さない旧Daemonは古いものとして扱う。

切り替えに失敗すると`Updates/last-error.txt`に記録し、次回起動時に表示する。アプリ本体はSparkleが置換済みなので、旧バージョンへの自動ロールバックはしない。必要なら古いZIPをR2（直近10件）から取得して手動で戻す。

## 初回セットアップ

一度だけ行う。`wrangler`はリポジトリにpinした`npx --yes wrangler@4.160.0`で実行する。

### 1. Sparkleの署名鍵

```sh
# SwiftPMが取得したSparkleのツールを使う（apps/macosでswift build済みであること）
TOOLS=apps/macos/.build/artifacts/sparkle/Sparkle/bin
"$TOOLS/generate_keys"            # ログインKeychainに秘密鍵を作り、公開鍵を表示
"$TOOLS/generate_keys" -x sparkle-private-key.txt   # CI用に秘密鍵を書き出す
```

- 表示された公開鍵 → GitHubのRepository variable `SPARKLE_PUBLIC_KEY`
- `sparkle-private-key.txt`の中身 → Repository secret `SPARKLE_ED_PRIVATE_KEY`。登録後はファイルを削除する。秘密鍵はKeychainにも残るので、別途バックアップを取る。

**鍵を失う・差し替えると、インストール済みのアプリは以後の更新を受け取れなくなる**（手動で入れ直しが必要）。

### 2. Cloudflare

```sh
cd infra/update-worker
npx --yes wrangler@4.160.0 login
npx --yes wrangler@4.160.0 r2 bucket create neuraos-updates
npx --yes wrangler@4.160.0 deploy      # https://neuraos-updates.<subdomain>.workers.dev
```

- 表示されたWorkerのURL（末尾の`/`なし）→ Repository variable `UPDATE_BASE_URL`。独自ドメインにする場合は`wrangler.toml`に`routes`を追加し、そのURLを設定する。**このURLはアプリに埋め込まれるため、後から変えると旧版は新URLを知らない。** 変える場合は旧URLでも配信を続ける。
- APIトークン（Account › Workers Scripts: Edit、Account › Workers R2 Storage: Edit）→ Repository secret `CLOUDFLARE_API_TOKEN`
- アカウントID → Repository secret `CLOUDFLARE_ACCOUNT_ID`

以後、`infra/update-worker/`の変更は`update-worker`ワークフローがmainへのpush時にデプロイする。

### 3. 確認

mainへのマージでReleaseが公開されたら、次を確認する。

```sh
curl -sS "$UPDATE_BASE_URL/appcast.xml"
curl -sSI "$UPDATE_BASE_URL/releases/neuraOS-<build>-darwin-arm64.zip"
```

## 旧updaterからの移行

native-76以前のアプリはGitHub Releasesから更新する旧updaterしか持たない。移行の手順:

1. このSparkle対応版をmainへマージする。R2とGitHub Releaseの両方に公開される。
2. 各Macで旧メニュー「アップデートを確認…」→「更新して再起動」。旧updaterがアプリとDaemonを入れ替える。新Daemonは`daemonBuild`を返すので、Sparkle版の初回起動でDaemonが二重に再起動することはない。
3. 以後の更新はSparkleで届く。
4. すべてのMacがSparkle版になったら、Repository variable `PUBLISH_GITHUB_RELEASE=false`でGitHub Releaseの公開を止める。リポジトリを非公開にしてよい。

旧updaterは非公開リポジトリでは`gh auth login`済みの場合だけ動く。非公開化はSparkle版への移行後に行う。

## 運用メモ

- ビルド番号は`github.run_number`。`CFBundleVersion`、Daemonの`daemonBuild`、appcastの`sparkle:version`、ZIP名が同じ番号になる。
- 公開ジョブはappcastに自分より新しいビルドがあれば何もしない。古いワークフローを再実行してもフィードは巻き戻らない。同じビルドの再実行は同じ項目を置き換える。
- `wrangler r2 object put`の上限は約300 MBで、現在のZIP（約160 MB）は収まる。超える場合はR2のS3互換APIでアップロードする。
- R2の無料枠は10 GB。直近10件（約1.6 GB）を保持する。R2からの配信に転送量の課金はない。
- リリースノートは更新ダイアログに表示される。現在はDaemon再起動の注意と元コミットだけ（`appcast.mjs`の`releaseNotes`）。
