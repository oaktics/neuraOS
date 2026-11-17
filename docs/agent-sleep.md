# 作業中の閉蓋スリープ制御

既定で有効。下バーのピルは現在の閉蓋動作を表示し、クリックすると詳細と履歴を開く（設定は変更しない）。詳細内の独立したスイッチで有効／無効を切り替え、その選択は次回の起動後も保持する。開始・解除中はスイッチ操作を受け付けないが履歴は開ける。「許可が必要」の場合は詳細内の「システム設定で許可」を使う。neuraOS → 設定（⌘,）→「閉じたまま作業を続ける」でも詳細の確認と切り替えができる。初回のみmacOSでスリープ制御ヘルパーの許可が必要。許可後は通常、オン／オフやアプリ再起動のたびに管理者認証を求めない。外部モニターは不要。起動時は、許可済みの場合だけ自動で開始する（起動だけでmacOSの許可ダイアログを出さない）。未許可の場合は、許可してアプリに戻った時点で開始する。安全上の解除や開始失敗の後は自動で再開しない。

初回は「有効にする」を押す。許可待ちになったら「システム設定で許可」からneuraOSのバックグラウンド実行を許可し、アプリに戻って再度有効にする。許可を取り消した場合は、同じ画面から許可し直す。通常の「無効にする」はスリープ制御だけを終了し、サービスの登録は残す。

macOSが登録記録を見つけられない状態（`notFound`）でも、有効化操作時に同梱ファイルを確認して登録を試す。ファイル不足の場合は再インストールを案内し、登録処理が失敗した場合はOSのエラードメインとコードを表示する。許可待ち・許可済みのサービスは再登録しない。`SMAppServiceErrorDomain: 1`（承認拒否）が返った場合は、状態の反映が遅れていても「システム設定で許可」を表示する。「ログイン項目と機能拡張」でneuraOSのバックグラウンド実行を許可してから、再度有効にする。

開始中から「開始失敗」に戻る場合は、設定画面で失敗理由を確認する。アプリ更新後に許可済みのまま開始できない場合は、無効な状態で「サービス登録を修復」を押す。旧登録の解除完了を待って現在のアプリを登録し直すため、macOSから再承認を求められる場合がある。修復後、再度有効にする。通常のオン／オフでは再登録しない。

- 全Workspaceの実行中のCodex / Claude Codeの `working` を集約する。アプリやターミナルの起動だけでは抑制しない。
- 1つでも作業中なら `pmset -a disablesleep 1` を保持する。
- Claude Codeのターン終了後も、バックグラウンドのシェル・サブエージェント・Monitor・Workflow・1回限りのwakeupが残っている間は作業中として扱う（Stopフックの `background_tasks` / `session_crons`）。次のStopで残りがなくなると解除する。終了しないdevサーバーなどで閉じたMacが起き続けないよう、バックグラウンドのみの状態は最長2時間で打ち切る。クラウドセッションと繰り返しスケジュールは対象外。フックが一覧を返さない場合は直前の値を保持する。
- 継続中に蓋を閉じると画面をロックする（設定でオフにできる）。ロック中もプロセスは動き続ける。`SACLockScreenImmediate` が使えない場合は `pmset displaysleepnow` で画面を消し、ロックはmacOSのパスワード要求設定に従う。
- 全エージェントが終了・指示待ち・回答／承認待ちになって5秒経過すると解除する。閉蓋中なら `pmset sleepnow` を要求し、開いていれば通常のスリープ設定に戻る。
- 不明な状態や接続断は完了扱いにしない。最大30秒の猶予後に抑制を解除する。状態が復旧すれば再開する。
- バッテリー駆動で残量10%以下、またはmacOSの温度状態が serious / critical ならセッションを終了する。
- 有効化後、設定画面が「作業中：蓋を閉じても継続します」になってから蓋を閉じる。通気のよい場所で使用する。

## 実装と復元

アプリは2秒ごとにユーザー所有の一時ファイルに作業状態を更新する。状態はイベント駆動で届くため、変化がないまま8秒経つと有効中に限りスナップショットを再取得し、長いビルドや長考の間も「作業中」を確認し続ける（20秒確認できなければ不明として扱う）。App Napを抑制して監視を維持するが、監視そのものはアイドルスリープを禁止しない。ヘルパーは所有者・ファイル種別・トークン・サイズ・スリープ中は進まない `CLOCK_UPTIME_RAW` による15秒の有効期限を検証し、シンボリックリンクを拒否する。通常のスリープでは期限を消費しないため、復帰直後にアプリより先にヘルパーが動いても認証済みセッションを維持する。起きている間に更新が15秒止まった場合は従来どおり解除する。入力からコマンドは実行しない。

同梱の `NeuraSleepService` を `SMAppService.daemon` で初回のみ登録する。plistは `Contents/Library/LaunchDaemons/app.neuraos.native.sleep.plist` に同梱し、`BundleProgram` で同梱サービスを起動する。パスワードを保存せず、sudoersも変更しない。許可済みサービスはXPCで必要なときに起動する。登録やMacの起動だけではスリープを抑制しない。

XPCは双方で同梱バイナリのdesignated requirementを検証する。配布クライアントとサービスはHardened Runtimeを有効にし、DYLD環境変数によるコード注入・デバッガ接続を許可しない。配布スモークは実際のアプリへのDYLD注入が拒否されることを、注入が成功する非保護の対照プログラムと比較して確認する。SIPが無効なCI環境ではOSの強制を検証できないため、その旨を明示して動的注入テストをスキップし、署名フラグ・禁止権限の検査は必須とする。ad-hoc署名のCEFにはTeam IDがないため、クライアントだけはライブラリ検証の例外を持つ。Developer ID署名の配布版は同一Team IDによるライブラリ検証を維持し、ad-hocの隔離検証とは区別する。サービスは接続元の実効UIDで監視ファイルの所有者を検証し、呼び出し元からUIDや実行コマンドを受け取らない。特権処理はサービス内の固定された `/usr/bin/pmset` 操作だけで、シェルやユーザー指定の実行ファイルを起動しない。

root所有の `/Library/Application Support/neuraOS Sleep Control/lock` の排他ロックが多重起動を防ぐ。設定変更前に同ディレクトリの `owned` を書き、通常終了・接続切断・監視期限切れ・SIGTERMで復元する。復元マーカーは再起動でも残る場所に保存する。クラッシュ時にはlaunchdが再起動し、残ったマーカーに基づいて復元する（セッションは再開しない）。復元失敗時もマーカーを残して再試行する。旧バージョンの `/var/run/neuraos-agent-sleep` が存在する間は新しいセッションを開始しない。

`SleepDisabled` が既に有効なら他アプリの設定を引き継がず拒否する。これはMac全体の設定なので、他の閉蓋スリープ制御アプリとの同時利用は避ける。OSバージョンや機種による動作差は実機で検証する必要がある。標準のIOPMアイドルスリープassertionだけでは閉蓋スリープを防げない。

アプリ更新後は、以前の接続がなくなったサービスが終了し、次回は更新された同梱バイナリが起動する。ad-hoc署名の検証版では、署名ハッシュが変わる更新でmacOSが再承認を要求する可能性がある。更新をまたぐ許可の継続は実機検証が必要であり、毎回のオン／オフでの認証削減と区別する。

サービスの登録解除・強制停止、アプリ削除、復元コマンドの継続的な失敗などで復元できない場合は、関連プロセスが終了したことを確認してから手動で復旧する：

```sh
sudo /usr/bin/pmset -a disablesleep 0
sudo /bin/rm -f "/Library/Application Support/neuraOS Sleep Control/owned" "/Library/Application Support/neuraOS Sleep Control/status"
```

## 検証

自動テストは全Workspaceの集約、バックグラウンド作業の保持と上限、既定で有効な選択の保持、完了と不明状態の区別、完了5秒／不明30秒の猶予、監視ファイルの所有者・トークン・期限・シンボリックリンク拒否、部分失敗時の復元再試行、低残量／高温時の終了、署名のない接続先の拒否、入力検証を確認する。実行時の電源設定を変更しない。

実機では電源接続／バッテリーそれぞれで、外部モニターなしの作業開始→閉蓋→全作業完了→スリープを確認する。あわせて以下を確認する：

1. 片方が作業中、片方が承認待ちでも継続する。イベントが1分以上出ない長いコマンドの実行中も継続する。バックグラウンド実行を残してターンが終わっても継続し、完了後に解除する。継続中に蓋を閉じると画面がロックされる。
2. 蓋を開いたまま完了すると強制スリープしない。
3. アプリ終了・強制終了、daemon切断、初回許可のキャンセル、ヘルパー強制終了・再起動で抑制が残らない。
4. 電源の抜き差し、スリープ後の復帰、再度の作業開始。
5. 別アプリが既にSleepDisabledを有効にしている場合は変更しない。
6. 初回許可後にオン→オフ→オン、アプリ終了→再起動→オンを繰り返し、認証が再表示されない。
7. システム設定で許可を取り消すと無効になり、許可待ちと再承認の案内が表示される。
8. 更新後に新しいヘルパーが起動すること、署名不一致の別アプリからXPC接続できないことを確認する。

`ioreg -r -n IOPMrootDomain -d 1` の `SleepDisabled` / `AppleClamshellState` と `pmset -g log` で、設定受理と実際のスリープを区別して確認する。


## 現在状態と履歴（#194）

設定の希望値、helper セッションの開始状態、OS の `SleepDisabled` 読み取り値は別の情報として扱う。ピルの「閉蓋でも継続」は、同じセッションのトークンを持つ helper の「作業中」報告が4秒以内、作業情報が20秒以内、OS の抑制が有効、かつ蓋情報を取得できる場合だけ表示する。古い確認や他アプリによる抑制は「不明」。解除・開始中は「確認中」、許可不足や制御失敗はその理由を表示する。完了／回答待ち後の5秒と作業状態不明の最大30秒は別の解除猶予表示。通常スリープは警告色にしない。アイコン・文言・VoiceOver ラベルを併用する。

「閉蓋でスリープ」は OS の抑制が無効で通常の電源設定に従うという意味で、外部ディスプレイ構成などを含む実際のスリープの保証ではない。「継続」も設定の確認であり、物理閉蓋後のプロセス進行を実証した意味ではない。詳細にこの区別を表示する。

### 保存場所の判断

履歴の所有者は **macOS アプリ** とする。既存の特権 helper は固定の電源操作と短命な lease 確認に限定され、native-core は複数 provider の状態と会話を管理する。一方、NSWorkspace の sleep/wake 通知、IORegistry の蓋・抑制状態、Network.framework の経路はアプリで直接観測できる。helper にユーザー履歴への書き込み権限を持たせず、daemon に macOS UI の寿命を仮定させないため、アプリで統合する。daemon は既存 summary listing に `providerConnection`（Codex の live RPC 登録、Claude の channel 確認状態）と `runtimeIssue` を追加する。後者は既存 agent 行に1件だけ保持する最新の Codex error 通知メタデータ（ランダムID・日時・turn ID・willRetryのみ）で、任意のエラー本文を含めない。専用イベントログはdaemonに作らず、連続エラーは最新1件へ集約する。接続登録だけの変化もlist revisionを進める。会話を開く際だけ既存の会話 API を読み取る。

保存先は `DaemonClient.dataDirectory/sleep-history/events.json`。専用データ領域を持つ開発ビルドもその領域だけに保存する。14日、2,000件、1 MiB のすべてを上限とし、ロード時もサイズ検証・保持期間適用、書き込みは atomic replacement、ディレクトリ0700・ファイル0600。30秒ごとと状態変化・正常終了時に観測時刻を保存する。破損／サイズ超過は不明期間として新しい記録を開始し、読み込みエラーを画面に残す。書き込み失敗も表示する。複数アプリが同じデータ領域へ同時に書く使い方は対象外（検証版は独立させる）。

保存項目は日時、列挙型のイベント・根拠・理由、判明する直前状態の開始観測日時、project/workspace/terminal/session/turn の opaque ID。タイトル、プロジェクトパス、SSID、IP、トークン、プロンプト、会話本文、任意のエラー文は保存しない。表示する期間は観測間の長さであり、初回に見つけた状態の開始日時は不明。対象 ID から関連会話を読み取り専用で開ける。削除済みや取得不能のセッションはエラーを表示し、別の会話にすり替えない。

### 観測範囲と限界

- **OS取得**: NSWorkspace の willSleep/didWake 通知、2秒ごとの `AppleClamshellState` / `SleepDisabled` 読み取り。通知はOSが通知した事実であり、外部測定による物理的な睡眠の証明ではない。取得不能な蓋状態も記録する。
- **アプリ観測**: helper の確認、Wi-Fi 専用 NWPathMonitor の経路利用可否、固定 HTTPS 確認先 `https://captive.apple.com/hotspot-detect.html` の30秒ごとの疎通（最大10秒 timeout、cookie/cache なし）、daemon 接続、provider 接続報告、ターン状態。Wi-Fi 経路は無線の関連付けや SSID の取得とは異なる。HTTPS成功は確認先への到達性であり、失敗もインターネット全体の断絶を断定しない。
- **アプリ観測（provider報告）**: Codex の error / willRetry 通知は、ターンを失敗扱いにせずエラー報告・再試行予定として記録する。同じ通知IDは再起動後も重複保存しない。実行中／回答待ちの同じ turn ID に対するエラーを観測し、そのターンの正常完了を後で確認した場合だけ復旧として扱う。過去ターンの通知は元の日時・IDの履歴として保存するが、現在のターンを障害扱いにしない。連続通知の間に複数のエラーがあっても最新メタデータだけを取得できる。
- **推定**: 実行中／回答待ちから interrupted へ変化し、そのターンの明示的な終了結果がない場合のみ中断を推定する。明示的な完了・失敗結果を優先し、古い別ターンの結果を流用しない。新しいターンは別の依頼かもしれないため、以前の失敗だけを根拠に再試行・復旧としない。再試行は provider の willRetry 報告として記録する。正常完了・回答待ちは失敗に含めない。接続断・未知の activity は正常完了とみなさない。
- agent の要約一覧を2秒ごとに全ページ取得する。途中で revision が変われば部分結果は採用せず、観測欠落を記録して次の tick で最初から取り直す。本文はデコード・保存しない。瞬間的な中断→復旧など、サンプル間の変化は失われ得る。
- アプリが起動していなかった期間、sleep/wake 間、10秒を超える監視遅延、agent 一覧を取得できない期間を欠落として記録する。停止期間中の OS ログを後から完全復元する機能ではない。再起動時の欠落開始は最後の保存時刻なので、最大30秒の保存間隔も含む。
- 同じ時刻に Wi-Fi と provider の障害が記録されても、因果関係は不明のままとする。helper が終了した理由の詳細は現在状態に表示するが、任意文字列の理由を履歴へ保存しない。

### 隔離検証

`NEURA_APP_ID=com.neuraos.sleep-history-test`、専用 `NEURA_DEV_DATA_DIR` / `NEURA_DEV_PORT` で `node scripts/native/build.mjs` を実行する。この bundle ID は共有の特権 helper の開始・登録・修復・設定変更をコード側で禁止するため、通常の LaunchDaemon 登録や電源設定に干渉しない。同梱 `Contents/Resources/Runtime/bin/neura-native-core` を同じ `NEURA_DEV_DATA_DIR` / `NEURA_DEV_PORT` で起動してからアプリを開く（検証版は LaunchAgent を登録しない）。`--sleep-history-fixture <output-directory>` は同じ実行ファイルで全8状態を light/dark の PNG として描画し、helper や daemon を起動しない。

自動確認: `swift test --package-path apps/macos`（状態導出、永続化、再起動の欠落、保持期間・件数・容量、秘密文字列の拒否、失敗／待機／再実行／復旧の分類）、`cargo test` in `crates/native-core`（接続と正常完了の独立性を含む）。fixture 画像はシミュレーション。隔離アプリの正常起動・popover・履歴保存・再起動は実アプリ確認として別に扱う。

未自動化の受け入れ条件: AC/バッテリーの双方・外部モニターなしで閉蓋→実作業継続→完了→スリープ→復帰、実 Wi-Fi 切断と実 provider の失敗／復旧、macOS許可操作、実 VoiceOver 読み上げ。これらは通常アプリでユーザーが手動確認し、時刻・電源条件・`pmset -g log`・作業進行を突き合わせる必要がある。隔離版の設定スイッチは操作できないため、helper 制御の実証には使わない。

### 2026-11-17 の実装検証結果

| 受け入れ項目 | 確認方法・結果 |
| --- | --- |
| 現在状態の導出、正常完了／回答待ちと異常の区別 | Swift unit tests。全体209件成功。helper未確認・OS情報なし・古い作業情報では継続表示にならない。 |
| 保存・保持上限・破損・再起動・秘密文字列 | Swift unit tests。隔離アプリでも再起動前12件のIDを全件保持し、停止137秒を欠落表示。ファイル0600、会話本文なし。 |
| provider接続とターン状態の分離、error/willRetry | Rust tests。`cargo test` 全体成功（lib 133件とintegration suites）。通知本文が要約へ漏れず、再試行通知で正常なworking状態を失敗へ変えない。実provider通信断は未検証。 |
| 全状態の見分け・明暗の外観 | 同梱実行ファイルのfixtureで8状態を描画。[light](architecture-evidence/sleep-history-194/footer-light.png) / [dark](architecture-evidence/sleep-history-194/footer-dark.png)。状態はシミュレーション。 |
| 下部バー、popover、設定と閲覧の分離 | 専用bundle ID・専用data/portの実アプリで確認。開閉と会話リンクで `agentSleepWanted` は書き込まれず、VoiceOver用AXラベル・値を取得。popover説明文の折り返しも確認。 |
| 対象セッションへの移動 | 隔離DBの明示的なシミュレーション用Claude transcriptを、同梱daemonの既存会話API経由で表示。実providerは起動しない。 |
| daemon切断／復旧 | 専用port 49194の同梱daemonだけを停止・再起動し、切断→41秒→復旧が時系列に残ることを確認。Wi-Fi経路とHTTPS成功の初回観測も記録。実Wi-Fi切断は未実施。 |
| AC/バッテリーでの物理閉蓋、完了後スリープ、復帰 | **手動確認が必要**。helper登録、ユーザーの電源設定、実データ領域は変更していない。設定受理と物理動作の証拠は別。 |
| VoiceOver実読み上げ、macOS初回許可 | **手動確認が必要**。AX情報の機械取得および状態fixtureまで。 |

追加の既存互換確認: `node --experimental-strip-types --test tests/native/client-capabilities.test.ts` 成功。隔離プロセスは確認後に終了。実アプリの画像と保存前後の検証データは作業worktreeの `.sleep-history-test/evidence/` に保存し、通常のデータや認証情報をリポジトリへ含めない。


### Tracker transition audit (PR #198)

The table-driven unit test `testAgentTransitionTable` covers 37 named sequences.
Every step also repeats the identical snapshot and requires no duplicate event.
Historical runtime issues retain their original timestamp/ID (and store deduplication);
they never mark a different turn troubled. An initial snapshot establishes a baseline,
not evidence that the current turn retried an earlier one.

| Transition group | Expected history |
| --- | --- |
| Restart: clean working; stale issue with completed or cleared last status | Historical provider event if present; no inferred retry; next completion is ordinary |
| Restart: active working/waiting issue, including willRetry | Provider error/retry report; waiting if applicable; same-turn completion can recover |
| Restart: completed/closed-completed turn plus historical issue | Historical report and completion/unknown; no new incident or recovery |
| Restart: failed/interrupted/closed-failed/unknown, with or without historical issue | Explicit outcome or unknown; a later unrelated turn is not retry/recovery |
| Same turn: working → waiting → working → completed | Waiting and completion only |
| Same turn: active error/retry → waiting/completed/closed-completed | Provider report, optional waiting, then same-turn recovery |
| Unscoped issue or issue first seen after completion | Provider report only; no inferred recovery |
| New working/waiting turn with previous issue | No retry/recovery inheritance |
| Failed/interrupted turn → new turn → completed | Failure/interruption remains history; new turn completes normally |
| Completion/failure before terminal closure | Matched turn outcome wins over session status |
| Waiting → interrupted without outcome; stale other-turn completion | Inferred interruption, linked to the observed active turn |
| Previous outcome and new active/waiting turn in one poll | Report old outcome separately; preserve new turn's own issue |
| Outcome arrives with unchanged session status | Report newly supplied outcome |
| Stale idle completion for a different active turn | Unknown, not completion/recovery |
| Completed/interrupted status churn | Do not replay the same outcome as a new incident |
| Connection down/up with clean, stale-issue, or active-issue turn | Connection observations remain independent of turn failure/recovery |

Separate regressions verify session disappearance clears cached evidence, inferred
interruption uses the observed turn ID and inference source, missing/mismatched turn
IDs do not mask interruption, and persisted provider reports contain no error text.
The archived `agentRetry` kind remains decodable for existing history; new retries
are recorded only as provider-reported `providerRetry`, not inferred from a new turn.
