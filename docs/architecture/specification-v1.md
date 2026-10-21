# neuraOS 技術仕様 v1.0 — 実装基準

設計基準日：2026-10-21。利用者が提示した17章の仕様を開発基準とする。この文書は実装時に参照する要点と変更記録であり、受け入れ結果ではない。

2026-10-21の追加指示：完成版を作成する。Supabaseを採用しない。個人専用、macOS、GitHubを最初の外部接続とする。金額上限は未設定とし、時間と呼び出し回数を制限する。

## 完成の定義

自然言語の目的からIntake → Context → Plan → Preflight → Execute → Verify → Deliver → Reflectを一つのタスクとして管理する。対象は調査、文書、開発、予定、事務を含む。CodexとClaudeの両方に対応し、再起動、バックアップ復元、権限、記憶の訂正削除、予算管理を含める。

ローカル実行は推論のオフライン動作を意味しない。外部モデルへの送信は情報分類と許可範囲で制限する。

## 境界

- Tauri/React Desktop：タスク・計画・進捗・成果物・承認・記憶・設定。任意シェルを直接実行しない。
- 独立Runner：ユーザー権限のLaunchAgent。UI終了と実行停止を分ける。ログアウト、スリープ、電源断を稼働不能として扱う。
- Cloud API：タスクの正本、認可、排他的実行権、実行要求、同期。Runnerから外向きTLSで接続する。
- PostgreSQL：正本。Object Storage：版付き成果物。SQLite WAL：ローカル耐久記録とoutbox。
- Policy / Tool Broker：具体的な操作を権限・内容ハッシュ・期限・計画版で検査する。
- Memory Resolver：適用範囲・出典・情報分類・版・失効を確認する。

## 不変条件

1. `operation_id` による重複排除と `expected_version` による競合検知。
2. Run内イベント連番の一意性、欠落検知、古い実行権のイベントの履歴化。
3. 記録と送信待ち登録は同一トランザクション。確認されたクラウド保存後にのみACK。
4. 実行権は期限と単調増加fencing tokenを持つ。同一タスクの副作用を二重実行しない。
5. 外部要求の結果不明状態を成功・未実行と推定しない。照合前の再送は禁止。
6. 承認は内容・対象・計画版・期限に結び付ける。変更後の再利用は禁止。
7. 記憶は権限を増やさない。外部文書の命令をユーザー指示へ昇格しない。
8. `standard / restricted / local-only` を区別する。`local-only` はクラウド同期とモデル送信を禁止。
9. 成果物は版を追加し、ハッシュと再取得によって検証する。
10. 完了は必須条件、成果物、証拠、承認、外部操作の解決、指定保存先を確認してから。

## データモデル

Workspace、Project、Task、AcceptanceCriterion、PlanVersion、PlanStep、Run、StepAttempt、AgentSession、Event、Action、Approval、Artifact、Verification、Memory、MemoryApplication、Connector、Device、Schedule、Usage、AuditRecordをタスクID・Run IDで関連付ける。プロバイダーのsession IDをTask主キーにしない。

初期実装の格納形式はADR-001を参照。仕様が要求する正規化・共有拡張・履歴・検索がすべて完成したという意味ではない。

## 記憶

Preference、Instruction、ProjectFact、Correction、Procedure、Episode。task / project / workspace / user-global の範囲を持つ。現在のタスク、プロジェクト指示、グローバル指示、検証手順、推測の好みの順で解決する。曖昧な矛盾は黙って統合しない。

明示指示は範囲を記録して有効化。推測は候補に留める。秘密情報を保存しない。本文、履歴、索引、埋め込み、キャッシュに削除を伝播する。復元前に最新の削除台帳を適用する。

## UI

Today / Tasks / Task Detail / Projects / Memory / Settings。目的と完了条件を優先表示し、ターミナルログは実行詳細で展開する。通常の利用に不要な内部実装情報を主画面へ持ち込まない。

## 受け入れ

- 両エージェントで代表タスクを完了し、途中の修正と計画版を追跡できる。
- UI終了後の継続、Runner再起動、切断、重複配送、停止、端末失効、結果不明送信を確認する。
- 別プロジェクトへの秘密流出、未許可ファイルアクセス、Broker迂回、期限切れ承認再利用を防ぐ。
- 50件以上の評価セット。定型タスク完了率90%以上を目標とする。重大な漏えいと権限違反0件を必須にする。
- 記憶あり／なし比較、利用者の主観評価、モックと実サービスの区別を含む。
- 目標RPO 15分、RTO 4時間、Run照合2分、停止5秒、ローカル表示p95 300ms、同期p95 5秒を実測する。

M0〜M6の通過条件は未確認のまま完了扱いにしない。実装・ローカル検証・実サービス検証・運用受け入れを別々に記録する。
