# ADR-001：個人利用向けの初期構成

2026-10-21 / accepted for development, not release acceptance

- Desktop、Runner、Cloud APIの三つを分離する。
- Node 24のSQLiteをWAL/FULLで利用し、クラウド送信待ちを耐久記録する。
- Cloud APIは標準PostgreSQLを使う。Neonが初期接続先候補。利用者の指示によりSupabase依存は除去した。
- R2への接続はS3互換インターフェースとし、保存後に本文を再取得してハッシュを検査する。
- 個人利用のためworkspace aggregateをJSONB行として保存する。行ロックで状態、イベント、操作IDを原子的に更新する。監査・検索・削除台帳は別テーブル。高頻度共有や大規模履歴には正規化が必要。
- RLSは非SUPERUSER・非BYPASSRLSロールで試験する。認証済みGitHub IDをトランザクションローカル設定に渡し、SQLの所有者条件と併用する。
- GitHub認証のscopeは本人確認に限定し、Issue書き込み資格情報とは別にする。端末要求はEd25519署名と端末失効状態も検査する。
- モデル呼び出しのプロセスはmacOS sandbox-execで隔離する。sandbox-execは長期的な公開APIではないため、OS更新時に実機試験を必須にする。未対応OSでは許可を広げず開始を拒否する。
- モデルからホストツールを使用させない。生成コードは別のネットワークなしコンテナで検証する。任意の既存リポジトリ編集への拡張は別の隔離設計と試験が必要。
- 実エージェント試験の代わりとしてfixtureを扱わない。fixtureは明示的な開発フラグでのみ有効にする。

将来の変更：正規化したRun/Action/StepAttemptテーブル、PostgreSQL全文検索とpgvectorの実利用、指示競合の解決、評価に基づく改善のshadow rollout、署名更新配布。現時点でこれらは完成済みではない。


## Desktop UI

- 2026-10-21の利用者の修正指示に従い、サイドバーと本文の背景を同色とする。濃色のサイドバー、強いカード装飾、大きなブランド表現を避ける。
- 左側はプロジェクトと所属タスク、および未分類のタスクを直接選べる一覧とする。プロジェクトを折りたためる。MemoryとSettingsは下部へ置く。
- ReactのUI基盤としてRadix Themes 3.3.0を採用。選択メニュー、ダイアログ、ボタン、入力、チェックボックスを共有コンポーネントで統一する。フォームの保存処理・認可は既存のRunner APIを維持する。
- コンポーネントのテーマは明るいニュートラル色、細い境界、控えめな選択表示。選択メニューは不透明な面にし、フォーカス・Escape・矢印キー操作はRadixの仕組みを使用する。
- React/ViteはTauri WebViewに適した既存構成を維持する。UI部品導入のために別のサーバーレンダリング基盤を追加しない。
- 参照: [Radix Themes](https://www.radix-ui.com/themes/docs/overview/getting-started)、[Select](https://www.radix-ui.com/themes/docs/components/select)、[Dialog](https://www.radix-ui.com/themes/docs/components/dialog)。

## 2026-10-21: 役割とローカルCLI

ユーザーの追加指定により、既存ログインを持つローカルCLIを利用する。CodexはApp Server、Claudeはインストール済みCLIのprint/stream-jsonを使う。SDKの別ランタイムは依存から除去した。資格情報は親の推論プロキシだけが付与し、隔離された子に渡す値はダミーとする。プロキシは推論エンドポイントだけを許可する。

副社長をグローバルの相談窓口、プロジェクト部長を計画・集約担当、社員を独立した実行タスクとして永続化する。各段階を既存のTask/Run/Artifact/Verificationに結び付け、chatとteam専用の型付きコマンドで操作する。部長の計画は2〜4件の社員タスクへ分割し、全員の完了後に集約を再開する。承認は最終集約後だけ許可する。

Claude CLIのJSON Schema処理はdraft 2020-12の宣言を受け付けないため、共通スキーマから宣言だけ除いて渡す。出力の検証は共通Zodスキーマで維持する。macOSではICUの時刻データ `/private/var/db/timezone` の読み取りが初期化に必要だった。秘密ファイル・外向き直接通信の許可は追加していない。
