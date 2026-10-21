# Neon / R2 / GitHub / Cloud API

外部リソースは自動作成していません。初回セットアップには各サービスのアカウントと配置先が必要です。

1. NeonにPostgreSQLプロジェクトを作り、管理用接続で `DATABASE_URL=... pnpm db:migrate` を実行する。
2. 実行専用ロールを `NOSUPERUSER NOBYPASSRLS` で作る。4テーブルにSELECT/INSERT/UPDATE/DELETE、publicスキーマにUSAGEだけを付与する。Neon標準の所有者ロールをAPIへ流用しない。
3. Cloudflare R2に非公開バケットを作り、そのバケットに限定したS3アクセスキーを作る。
4. GitHub OAuth Appを登録しdevice flowを有効にする。本人確認用途のscopeは `read:user`。外部Issue作成用のfine-grained tokenは別にする。
5. DockerfileをHTTPS対応のコンテナ環境に配置する。Cloud APIは常時起動するプランを利用する。無料のスリープするホスティングでは定期実行の時刻を保証できない。
6. `.env.example` のCloud API側変数を秘密設定へ登録する。`NEURA_ALLOWED_GITHUB_IDS` はGitHubの数値ユーザーID。ユーザー名の変更に影響されない。
7. Desktop設定にCloud API URL、OAuth Client ID、Workspace IDを保存し、Runnerを再起動する。
8. GitHubログインを完了し、この端末を登録する。認証トークンと秘密鍵はKeychainに保存される。
9. Cloud APIに `NEURA_SCHEDULER_OWNER=github:<id>` と `NEURA_SCHEDULER_WORKSPACE` を設定する。
10. クラウド保存必須の試験タスクを実行し、成果物の再取得、別のRunnerキャッシュからの読取、端末失効、通信断を実際に検証する。

### 保守

- Neonのバックアップ・履歴保持設定がRPO 15分を満たすか契約と設定を確認する。無料枠で満たすとは仮定しない。
- R2オブジェクトキーは成果物ID・ハッシュで一意にし、上書きを拒否する。別障害領域への複製・バックアップは追加で設定する。
- GitHubトークン失効時は再ログインする。短命OAuthトークンの自動更新フローは現在未実装。
- API健康確認 `/health` は認証不要。タスク、記憶、成果物、端末操作には認証が必要。
- DB管理ロール、R2キー、GitHub資格情報をDesktopへ埋め込まない。

### 参照した一次資料

- [Neon connection pooling](https://neon.com/docs/connect/connection-pooling)
- [R2 AWS SDK for JavaScript v3](https://developers.cloudflare.com/r2/examples/aws/aws-sdk-js-v3/)
- [GitHub OAuth device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Claude Agent SDK permissions](https://code.claude.com/docs/en/agent-sdk/permissions)
- [Tauri capabilities](https://v2.tauri.app/security/capabilities/)
