# DB接続ロール

Cloud APIには SUPERUSER / BYPASSRLS / テーブル所有者ロールを使用しない。
マイグレーションは別の管理ロールで適用し、実行ロールには4テーブルへの SELECT/INSERT/UPDATE/DELETE のみ付与する。
APIはGitHub `/user` 応答と数値IDの許可リストを検証後、トランザクションごとに `set_config('neura.user_id', verifiedSub, true)` を設定する。
RLSに加えて `workspace_id` と `owner_id` をSQL条件へ含める。

個人用の初期実装ではタスクなどのエンティティをworkspace JSONB aggregate内に保持し、行ロックで状態・イベント・操作IDを原子的に更新する。
監査、全文検索、削除台帳は別テーブル。検索索引の内容も同じトランザクションで削除する。
この方式は大規模共有向けの正規化スキーマではない。スケール移行はADR-001を参照。
