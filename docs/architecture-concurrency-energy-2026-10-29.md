# neuraOS: 10子並列時の安定性・電力と基盤再設計

2026-10-29の設計検討と実装検証。以下の推奨構成は検討時の仮説を含む。現在の実装・検証済み範囲は次節で区別する。
調査基点 HEAD: `d7c779ac4a11a8eaed615770d2713b9182676f63`。
独立workspace: `a992dc6c-27f7-4853-8f97-434be3c5324e`。

## 実装と検証の現在地

製品の常駐daemon・PTY管理・保存・provider監督・MCPはRustへ統合する。通常のPTY/setup/Codexは直接spawnし、daemonごとに1つの共有supervisorでreserve ACK→token環境→spawn→attachを管理する。supervisorはDB開始前にprofile lifetime flockを取得し、旧子孫のcleanup完了まで保持する。provider-hostは互換fixture用で通常のper-agent hostではない。イベント監視・所有token・macOS上の制約は[native process ownership](native-process-ownership.md)を参照する。Swift UI、CEF、外部の`claude`・`codex`・`git`・`gh`は役割を保つ。「外部CLIを使う」はneuraOS自身にNode runtimeを残す意味ではない。ビルド・回帰試験用Nodeと、外部CLI側が必要とするランタイムは配布daemonと区別する。

統合中の実装は認証付きHTTP command＋WebSocket変更通知＋cursor付き出力取得を使う。UIのstate/terminal/browser定期pollを通知へ置換し、入力と出力取得の待ち行列を分ける。PTYは共有mio reactor、保存は単一SQLite writerと出力read threadを持ち、control/bulkのcreditとFIFOを分離する。bulkが満杯でもcontrolを受け付け、barrierは両laneの受理済み書込みを待つ。端末数の固定上限とは異なる。出力の`data`と`chunks`の二重転送は新UIでは行わない。CEFはネイティブUIの埋込みを維持し、callback駆動pumpと33ms fallbackを使う。

UDS binary、shared memory、segmented journal、別browser hostは以下に残る設計候補であり、実装済みと数えない。これらの優位性を今回の測定が証明したわけではない。Rustという言語名だけを根拠に最高性能を達成したとも結論しない。

[旧daemonのHTTP/PTY測定](architecture-evidence/legacy-daemon-pty-2026-10-29.json)と[ネイティブ開発checkpoint](architecture-evidence/native-debug-pty-2026-10-29.json)では、10・20・32個の実PTYへ各1024行の約2KiB出力を流し、HTTP error・行欠落・重複0、Unicode保持、終了後のcursor replay一致を確認した。後者は最適化前debug binary、同時に別build/agentが稼働した単発標本であり、実Claude仕事量・電池寿命・最適化版の公平比較を示さない。開発checkpointには未統合の操作が残るため、この証拠だけでリリース完了にはしない。

実native ProviderServiceからfake Claude／Codexを各10/20/32起動した[並列fixture](architecture-evidence/native-provider-daemon-parallel-2026-10-29.json)では、全指定数の同時active、登録・入力・turn event・exit、UI stream切断後のcursor replayを確認した。これは実モデル負荷でも公平な性能比較でもなく、provider App Server再接続の証明ではない。[Node→Rust→Nodeデータ移行](architecture-evidence/legacy-native-data-migration-2026-10-29.json)も隔離DBで成功したが、実installed app／LaunchAgentの更新とは区別する。最適化版idle/load比較とrelease受入は保留。

## 調査時点の判断と比較候補（実装仕様ではない）

**推奨はRust/native core＋Swift UI＋薄いprovider adapter＋分離したブラウザ実行環境**。実装コスト、既存資産再利用、移行容易性は性能ランキングから除外する。目的は、PCの資源が許す限り有用な仕事を並列実行し、最大持続throughputとp99応答性を両立させ、CPU・起床・IO・メモリ・energyの管理overheadを最小化すること。4/10/20 activeや同時起動2件などの人為的な製品上限は設けない。20は測定点であり上限ではない。

これは**測定前の設計推奨**であって「Rustが最速と実測済み」という結論ではない。Rustを選ぶ理由は、GC pauseを持たない所有モデルとコピー/割当/queue/schedulingの明示制御を、PTY・保存・IPCの共通hot pathへ適用する設計上の適合性。言語を変えるだけでは競合は消えない。同一仕事量・同一耐久性・同一機能の比較でSwift/nativeまたは改善Nodeが優れるなら、その測定に従って選択を変更する。

現ログとコードは共有資源競合を**示唆**するが因果を確定しない。build60と62は観測時間・実並列数・作業内容が違い、timeout件数を改善率へ換算できない。今回の合成Store/HTTP負荷は実10Claude・実バッテリー寿命・提案Rust構成の性能を証明しない。旧版の「既存資産/工数を理由にNode継続を第一候補」「固定active数によるadmission」は撤回した。

## ゼロベース推奨構成と性能仮説

```text
Swift UI: immutable view state / visible terminal GPU presentation
    | control: authenticated UDS framed binary RPC + revision delta
    | terminal: separate bulk stream; shared memory only where measured beneficial
Rust core process
    ├ control owner: deterministic lifecycle, operation/turn/epoch IDs
    ├ kqueue/nonblocking PTY reactor + fair per-session queues
    ├ bounded CPU workers: incremental VT parse / transcript parse / indexing
    ├ dedicated storage threads: metadata SQLite + segmented output journal
    └ event-driven process supervision / provider thin adapters -> existing CLIs
Browser-host boundary -> CEF browser / renderer / GPU processes
    ↔ UI presentation and browser actions (native integration PoC required)
```

**プロセス/スレッド**: 稼働agent数に比例するneuraOS daemon/worker poolを作らない。coreは少数の長寿命reactor/CPU/storageスレッドを持ち、CPU poolはコア数と実測負荷で調整する。セッション数とスレッド数は別物。control ownerは業務状態の唯一の決定者だが、IO・parse・圧縮・履歴scanをそのqueueで実行しない。大量のPTY dataはcontrol ownerを通さずsession data workerへ流す。session内順序を保証しsession間を公平にscheduleする。独立core数をむやみに増やして全stateを複製しない。共有状態ownerが限界になったらtenant/session shard＋上位の小さなregistryへ分割できるprotocolを持つ。

**provider**: CLIの既存login/resume/permission/MCPを保ったthin adapter。可能ならCLIの公式structured event APIを利用し、PTYはinteractive機能が必要な経路に限定する。ただしSDK/headless化で対話機能や設定が変わる場合は代替完了としない。providerごとのNodeが必須ならhot pathに置かず、不要なruntime/process複製を避ける。provider本体のCPU/RSS/課金はneuraOS管理overheadと別会計。外部CLI自体を軽量化できない範囲を明示する。

**ストレージ**: metadata/command resultは単一writerのSQLite WAL、group commit、prepared statements、read snapshot。PTY outputはSQL row毎の追加をやめ、sequence/resizeを含む長さ・checksum付きsegmented append journalへ順次書込し、粗いoffset indexでseek/replay。commit境界のdurable cursorをmetadataに保存し、tail checksum/lengthでtorn writeを検出する。journal→fsync→metadata cursor commitの順序、再起動時のorphan segment扱いを仕様化する。terminal出力の圧縮はcold segmentだけ低優先度で行い、live pathではCPUを浪費しない。履歴保持は明示容量とretention policyで管理し、消去範囲をユーザーへ示す。FULL相当の耐久性を保った比較を必須とする。SQLite単体で同等以上ならjournal追加の性能仮説は棄却する。

**IPC/コピー**: local controlとbulk outputを別streamにし、UDSのframed binary messagesを第一候補とする。全snapshot JSONを定期配信せず、変更のあるrevision/entityだけ送る。bulkはbuffer ownership/byte offsetを渡し、同じ出力をdata/chunksに二重格納しない。大きな連続出力は固定容量shared-memory ring＋通知doorbellを比較し、コピー削減が同期/メモリ帯域費用を上回る場合だけ採用する。世代/境界検証、consumer credit、read-only mappingなどが必要で、共有メモリを無条件に最速としない。XPCは権限境界やservice lifecycle、HTTP/MCPは外部互換境界に限定する。

**PTY/描画**: VT parseとterminal protocol replyをbackgroundで継続し、Swift MainActorにはvisible cell/dirty regionの差分だけ渡す。表示更新はdisplay cadenceに合わせて合流し、不可視端末はscreen modelを保つがpaintしない。scrollback全再描画・全state Observation更新を避け、Metal/既存rendererを同一画面fixtureで比較する。入力/resize/permission/cancelはoutput洪水と別budgetに置く。現SwiftTermの機能を失った高速化は採用しない。

**CEF**: terminal/controlとブラウザの故障・workload境界を分けるため、専用browser hostとCEF renderer/GPUのプロセス群を推奨する。native UIとのpresentationは共有GPU surface経路を検証し、CPU bitmap copyを増やす分離は性能目標を満たさない。CEFの実SDKでsurface連携・IME・アクセシビリティ・popup/modal・download・拡張機能の互換性は未検証であり、設計の最大のPoC項目。実測で転送が支配的ならbrowser hostをnative UI側へ戻し、control/coreの隔離は維持する。pumpはCEF callback＋SDKが要求するfallbackを用い、再入やAppKit event競合を避ける。完全timerゼロは前提にしない。

**性能のtradeoff**: batchを大きくするとthroughput/IO効率が上がる反面p99と未commit tailが増える。shared memoryはコピーを減らすが常駐容量と同期費用が増える。process分離は故障隔離を改善するがIPC/起床/RSSを増やす。圧縮はIOを減らすがCPU/energyを使う。高並列は総Wattを増やし得るが仕事完了が早まりJoule/jobが下がる場合もある。最大仕事量モードと省電力モードは混同せず、既定では有用throughputを維持して無駄なoverheadを削減する。比較はp99制約下のjobs/s・bytes/sとCPU秒/job・Joule/jobのPareto frontierで行う。

## 技術スタック比較（実装コストを評価軸に含めない）

| 案 | 性能上の期待 | 性能上の懸念・反証条件 | 判断 |
|---|---|---|---|
| Rust/native core＋Swift UI＋thin adapters | hot pathの割当/コピー/queue制御、GC無し、PTYとIOのevent駆動 | actor直列化、blocking IO混入、IPC複製があれば利点を失う。同一traceで比較が必要 | **推奨する1案** |
| Swift/native core＋Swift UI＋XPC | native統合、コピーやserialization削減の可能性 | ARC traffic、actor reentrancy、cooperative executor上のblockingを測定 | 最有力の対照候補。Rust優位は未証明 |
| Node/TS＋専用writer/worker＋stream | async IOで高throughputを達成できる可能性 | JS parse/serialization/GCと複数V8 isolateの常駐量、hot path境界のcopy | 同一仕事量の比較対象。資産再利用を理由に優先しない |
| C/C++ native core | allocation/IOを同程度に明示制御可能 | Rustより速い保証はない。データ競合/寿命不整合による故障も性能可用性を損なう | 基準を上回る測定がなければRustから変更しない |
| Electron等のweb UI / Tauri shell | browser rendererの最適化や既存GPU pipeline利用 | terminal/UI用途の別runtime/DOM/layout/IPC overhead、既存CEFとの重複 | 本件の最小overhead目標では非推奨。測定で逆転可能 |
| headless provider SDKのみ / remote worker | PTY描画削減 / 別マシンに計算分散 | CLI対話機能を維持できない場合あり。remoteはnetwork latency/転送と別PCの電力を隠す | 任意実行modeとして比較、local PC性能の達成に算入しない |

専用IO/parseの分離とbounded queueは言語と独立した条件。[Node worker threads](https://nodejs.org/api/worker_threads.html)、[DatabaseSync](https://nodejs.org/download/release/latest-v24.x/docs/api/sqlite.html)。Rustのbounded mpscは容量が尽きたproducerを待たせる仕組みでありagent数上限ではない。[Tokio mpsc](https://docs.rs/tokio/latest/tokio/sync/mpsc/index.html)。

## IPC/配信方式比較

| 方式 | 適性 | 判断/注意 |
|---|---|---|
| 現HTTP short polling | debug容易、互換維持 | 移行fallbackとして残す。1件の変更で全一覧を繰返し読む形は廃止 |
| HTTP commands＋SSE state events | 片方向revision差分、再開cursor、既存認証を再利用 | 外部/移行互換用。native hot pathはUDSと比較し、snapshotとstreamの境界、gap時resyncを保証 |
| WebSocket terminal stream | 双方向input/output/resize、低頻度接続、frame batching | 外部/remote向け候補。local UDSより優れるかは測定。fairness、byte quota、ACKをapp protocolで定義 |
| Unix domain socket＋framed messages | local ACL、低overhead、PTY/adapter内部 | native UI/core/provider間の第一候補。binary framingと別control/bulk stream、認証/権限検証を設計 |
| XPC | macOS helperの認証/lifecycle/権限境界 | 権限service/lifecycleに採用。bulk hot pathはUDS/shared memoryと比較。XPCのserialization/copy費用は測定 |
| MCP stdio / Streamable HTTP | provider client互換と標準準拠 | CLIとのstdioは維持。独自native SSEをMCP SSEと混同しない。接続を集約する際はCLI対応versionを固定検証 |

MCPの2025-03-26と2026-07-28ではHTTP transport/session/GET streamの仕様が違う。最新draftだけを見てCLI互換を想定しない。[公式versioned transports](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-03-26/basic/transports.mdx)、[2026-07-28](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/basic/transports/index.mdx)。

## 比較検討案の契約（現行仕様はperformance.mdを参照）

1. **単一の状態所有者**: control actorのみがtask/workspace/terminal lifecycleを遷移。provider adapterは観測eventを送るだけ。writerは永続化所有者であり別の業務状態ownerではない。mutation→writer transaction commit ACK→revision公開の順。snapshotはimmutableでrevision付き、UIが独自にworking/completedを確定しない。
2. **stream**: 初回snapshot revision R、その後R+1から差分。接続epoch/session/terminal/turn IDを含める。重複はsequenceで無視、gap/retention超過はsnapshot取得。UI publishは16–33ms coalesceし、不可視workspaceのview invalidationを抑制。
3. **永続化**: outputはterminal sequence+byte offset、resize markerも同順序。memory受理とdurable ACKを別にする。metadataとcommand resultはFULL commit後ACK。outputの耐久性を下げるなら最大未保存bytes/timeをユーザー契約に明記。現16msは硬い上限ではない。読み取りはwriter flushを強制せずcommitted prefix＋ownerの未commit tailを整合snapshotで扱う。SQLite NORMALへの一律変更はしない。[SQLite WAL](https://www.sqlite.org/wal.html)。
4. **上限とfairness**: メモリ/IOに応じてbyte creditとqueue budgetを決める。試験時のstream256KiB/terminal、全体8MiB等は比較パラメータで、固定の製品容量やagent数制限ではない。session内の順序保証とsession間のweighted fair schedulingを両立する。FULL/ENOSPC/slow consumer時はproducer pauseまたはdurable spoolのquotaへ。control/cancelはbulkと別priority。PTYを停止するとterminal protocol replyが詰まるため読み取り/制御返信経路を別budgetで継続。黙って出力dropしない。
5. **キャンセル**: queue入り時に絶対deadline、実行前に失効検査。readは接続消失でcancel。mutationの途中cancelはtransaction/外部副作用境界で止め、unknown/completedを照会可能にする。timeout表示にoperation IDと状態照会を対応させ、terminal inputは自動再送しない。
6. **冪等性と再接続**: operationId+payload hashを永続化し、実行中/完了/不明を照会。Channels instructionにもdeliveryId/ACKを追加し、CLIで同じIDが消費済か確認できない場合はunknownとする。exactly-onceを宣伝せずat-least-once event＋dedupe、外部副作用は結果不明を明示。retryはread/接続に限定し指数backoff100ms〜10s+jitter、最大1inflight、budget全体を継承。
7. **資源に応じたbackpressure（人為的な並列数制限なし）**: 登録数/active数/同時起動数の固定capを設けない。利用可能メモリ・disk空き・queue byte数・実際のconsumer速度を測り、満杯の経路だけcreditを減らす。CPU-heavy準備/parseはfair schedulerへ渡し、control/cancelの応答budgetを維持する。実資源が確保できない起動はその理由と待機状態を可視化し、実行中agentを黙ってkillしない。loop遅延だけで一律にactive数を落とさず、詰まっている資源と原因を提示する。10activeの実用運転を設計目標とし、その先もPCの限界まで伸ばす。資源待機になったagentはactive達成数へ数えない。
8. **監視**: hookを主経路、transcriptは変更通知＋stat gate＋offset incremental parse。truncate/replace時reset、同一turn/session照合と完全flush検査を保持。低頻度reconciliationを残す。通知は合流/欠落し得るのでfs eventだけで完了判定しない。
9. **process lifecycle**: PIDだけでなくstart identity/PGID/所有leaseを保持。ps全表scanは共有監視1箇所にまとめ、通常はpipe EOF/exit event、停止時に子孫追跡を強化。親crash/孫reparent/別PGIDの保証を維持し、wakeups削減のために既存孤児回収を単純削除しない。
10. **UI/CEF**: 端末protocol処理と再描画を分け、不可視端末も入力応答を維持。CEF pumpは担当間調整の別実装。OnScheduleMessagePumpWorkを使っても完全無timer化を約束しない。現在のCEF公式headerはcallback以外のfallback pump（約33ms推奨）も要求する。実際に固定したSDK版で確認し、modal/menu回避と再入防止を保持する。[CEF公式header](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_browser_process_handler.h)。

## 撤回した段階的実装計画とrollbackの検討記録

以下の段階表は調査時点の計画であり、段階ごとの後日実装・承認という進め方はユーザーの指示で撤回した。今回の統合PRで配布runtime、provider、PTY、保存、UI通知、更新helperまで実装・検証し、一括リリースする。表に含まれるUDS/shared memory/journal/別browser hostは比較候補であり、今回採用した構成の未実装部分とは扱わない。現行の構成と測定結果は[performance.md](performance.md)を正とする。現Nodeは既存機能の比較基準・移行中の互換経路として利用できるが、既存資産や検証の早さは最高性能の証明でもNodeを製品の最終構成へ採用する理由でもない。旧版の暫定4activeは未計測の保護案にすぎず、最新方針では製品上限としても推奨値としても採用しない。10activeを実用運転できず資源待機が発生した条件は10並列目標未達と記録する。

| 段階 | 変更/検証 | exit gate / rollback |
|---|---|---|
| 0 | build/CLI/負荷/睡眠状態、route総数、stage latency、queue/flush bytes、UI/pump signpost | 固定rateの独立producerと外乱なしbaseline。秘密payloadなし |
| 1 | Rust/native/Swift/改善Nodeを同じcontrol・PTY・storage workloadで比較 | 最大持続throughput、p99、CPU/IO/常駐量を同一耐久性で比較。コストでrankingしない |
| 2 | 推奨native coreのUDS/delta、PTY parser/描画差分、writer/journal | Unicode/resize/permission/Stop/ACK/replay一致。旧coreとのshadow read比較、single writer厳守 |
| 3 | browser host/GPU presentation、薄いprovider adapter、イベント監視 | CEF UI機能/拡張互換とcopy/energyを実測。分離が性能を損なえばhost境界を再配置 |
| 4 | resource-credit/fairness、fault recovery、scaling sweep | 機械の実限界とSLOの境界を測定。10/20を上限にしない。capabilityで旧経路へrollback可能 |

段階ごとの後日承認や小分けリリースは行わない。今回の[統合PR #133](https://github.com/oaktics/neuraOS/pull/133)にまとめる。実装済みupdaterと初回移行・復旧の仕様は[開発・配布フロー](development-release.md)を参照する。調査時のrollback案はwriterをdrain→durable cursor保存→単一ownerを切替。破壊的schema migrationを避け、DB backup/restore rehearsalは独立データで先に検証。ユーザー機能はClaude/Codex/shell、既存resume、worktree setup、親子監視/report ACK、通知、入力/resize/replay、browser/download/MCP、GitHub、sleep制御を維持する。plugin/CLI仕様差はadapterで吸収しCLIのglobal設定を書き換えない。

## 計測可能な受入基準（提案、未達成の項目を含む）

固定端末・OS・CLI版・電源/輝度・thermal条件を記録し、1/5/10/20子をそれぞれ10分idle、30分active、30秒burst、各3回。fake CLIを別processから固定rate送信（生成予定時刻からlatencyを測る）し、10子100KiB/s/子、burst1MiB/s/子。1visible/残りbackground、全visible相当、browser有無を分ける。成功readも総数集計しprovider API時間をlocal SLOから分離。課金10子試験は別承認・少数canary後。

| 指標 | 1子 | 5子 | 10子 | 20子 |
|---|---:|---:|---:|---:|
| local control latency p95 / p99 | 50/150ms | 75/200ms | 100/300ms | 150/500ms |
| input→PTY ACK p95 / p99 | 40/100ms | 50/150ms | 75/200ms | 100/300ms |
| state event→UI p95 / p99 | 100/250ms | 150/300ms | 200/500ms | 250/750ms |
| timeout率（local、非fault） | <0.01% | <0.01% | <0.01% | <0.01% |
| idle daemon CPU（1core=100%） | <0.5% | <1% | <1.5% | <2% |
| idle daemon interrupt wakeups/s | <5 | <7 | <10 | <15 |
| native idle CPU（static terminal、browser別） | <2% | <2% | <3% | <4% |
| native idle wakeups/s（CEF無し / 有り） | <10 / <50 | <10 / <50 | <15 / <50 | <20 / <60 |

1/5/10/20はbenchmark点であり製品制限ではない。20以降は32/48/64…へ、限界近傍は細かい刻みへ変えてscaling sweepする。安全な独立試験環境でmemory/IO/thermal pressureとp99が維持できる最大持続throughputを探り、各Nのoffered load・achieved throughput・backlog傾向・実active数を併記する。実資源不足で一部が待機した場合、**10/20 activeを達成したと数えない**。active数と登録数を別表示。throughputを減らしてlatencyだけ達成することも不可。全条件で出力連番/byte hash/resize順序の欠落0・重複0、permission/waiting/Stop誤完了0。steady backlogは上限内、30分のdaemon RSS増加<20MiB、total memory pressureが持続criticalに入らない。

energy proxy: 同一trace/同一仕事量で既存build62比CPU秒とdisk bytesを30%以上、idle wakeupsを70%以上削減する目標。外部CLIを含む/除く値を併記し、端末処理完了件数で正規化する。powermetrics等によるWatt計測は別の統制試験で行い、proxyから電池寿命を断定しない。timer削減はAppleの省電力原則に沿うが、rateと消費電力の比例を仮定しない。[Apple Energy Efficiency](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)。

復旧試験: isolated daemon/provider/writerを別々に停止、socketを5/30秒切断、writer5s pause、ENOSPC/permission failure、巨大chunk、古いACK/重複event、transcript replace/truncate、睡眠復帰を注入。接続復帰後5s以内にstate一致、control継続p99<500ms（writer故障時は明確なdegraded/拒否）、durable ACK済出力欠落0、未ACK tailは契約上限を検証、結果不明commandの自動再実行0、残留子孫0（明示停止後5s、所有関係のみ）。UI foreground操作・browser modal/menu・Unicode画面snapshotを回帰比較する。**この提案表の全条件を網羅したsuiteは未実施**。実施済みのプロセス終了・キャンセル・crash・予約pressure・移行・出力replay・browser回帰は[検証checkpoint](development-release.md#native統合の検証checkpoint2026-10-29)に記録する。

性能確定の追加gate: 同じPC・同じ仕事量のCLI-only基準に対し、10activeで有用throughputを少なくとも90%維持し、neuraOS管理費用のCPU秒/job・IO bytes/jobを報告する（90%は提案SLOで未測定）。各Nで到着率を上げ、30分backlogが増えずp99を維持できる最大rateを探索する。N増加でjobs/sが伸びなくなる点、p99破綻点、Joule/job最良点はそれぞれ別に示す。最良値の単一試行ではなく反復の信頼区間でRust/Swift/Nodeの優劣を判定する。

## battery/overheadを分離する評価手順

今回のprocess標本は管理下のCLI子孫・ビルド・テストhelperを含む。単純なtree合算をneuraOS固有overheadと呼ばない。以下は今後の統制試験であり今回の実バッテリー検証結果ではない。

| 条件 | 測るもの | 差分の意味 |
|---|---|---|
| A: 同じPCの安定idle、neuraOS/CLI無しの試験環境 | OS/background baseline | 実ユーザーアプリを止めず別試験環境で作る |
| B: 固定仕事量のCLIのみ、同じprovider/cache/context | CLI/API/tool本来のCPU/IO/RSS/energy | 有用な仕事の基準。network待ちとCPU作業を分離 |
| C: neuraOS管理下でBと同じCLI仕事量、terminal UI非表示 | core/adapter/保存/監視を加えた費用 | C−Bを管理overheadの候補とする。CLIの終了時間や出力が変われば条件不一致 |
| D: C＋固定visible terminal trace | UI/VT/描画の追加費用 | D−Cを表示overheadの候補とする |
| E: D＋固定browserページ/操作 | browser/CEFの追加費用 | E−D。拡張・ページ内容・GPU状態を固定 |

各条件は同じ完了仕事数・出力byte数・耐久性で比較し、実行順をランダム化して最低3回、区間差とばらつきを報告する。CLIプロセス群、neuraOS core/adapter/UI、CEF browser/renderer/GPU、OS/backgroundを別系列で記録する。Node helperがproviderなのかneuraOS adapterなのかを所有roleで区別する。pressure/thermalは非線形なので差分を単純な因果係数とは見なさない。

拡張担当のビルド/検証が重なる今回の標本は参考資料にとどめる。統制試験では他作業の無い専用窓を用意し、同期していたビルド・compiler/リンク・disk scanを記録して外乱窓を別集計する。ホスト全体のWattとrole別CPU/IO/wakeupsを併記し、role別WattをCPU比率だけで推計しない。battery比較は輝度・電源状態・無線・thermal・充電状態・試験時間を固定しJoule/jobとjobs/sを同時に報告する。実10Claudeの仕事量再現とprovider費用のある試験は別途計画し、今回のStore/HTTP合成値から代用しない。

## 以下は移行前の調査記録（2026-10-29）

以下のbuild57/60/62、Node/TSのファイル名・固定poll・ベンチマークは当時の証拠として保持する。「現状」「現行」「HEAD」は調査当時を指し、冒頭のnative統合構成を指さない。旧harnessの実行結果をnative runtimeの検証として流用しない。

## 調査範囲と証拠の強さ

- リポジトリ内および確認した親ディレクトリに追加AGENTS.mdは見つからなかった。登録済み独立worktreeを使用。別エージェントのChromium拡張コードは変更しない。
- 実アプリ/daemonの再起動、停止、実DB・設定・ログの変更なし。生のargv、環境変数、会話、tokenは出力しない。既存診断ログはallowlist集計、クラッシュはbuild/例外型/関数名のみを確認。
- build62: `~/Applications/neuraOS.app/Contents/Info.plist` の `CFBundleVersion=62`。実プロセスの実行ファイルも同bundle。Runtime/apps内30ファイル（daemonソース）はcheckoutと全てbyte一致。**Swift/CEFの実行バイナリをソースと再現ビルドで同一性検証したわけではない**。nativeの実装値はHEADからの読解。
- `aafbb47` (#125) がoutput batch/state分離、`7b9bbbb` (#121) がClaude補完、`69c8c38` (#124) がChannels失敗の区別。現HEADはこれらを含む。build60のbundleは残存確認していないので、現在の改善コードが当時と同じだったとは推定しない。
- [診断集計](architecture-evidence/diagnostics-summary.json)、[プロセス標本](architecture-evidence/process-sample.json)、[合成負荷](architecture-evidence/synthetic.json)、[出力burst再実行](architecture-evidence/output-burst.json) を添付。統計はこの標本だけの値。

## 移行前の構成マップ

```text
SwiftUI/AppModel -- GET state 1s --------------------+
SwiftTerm       -- GET output 60ms/500ms + commands -+--> Fastify / 単一Node event loop
Browser bridge  -- POST native/poll 200ms ----------+       | 同期DatabaseSync/WAL/FULL
MCP stdio helper-- fetch HTTP (250s deadline) -------+       | agents/state/output/operations
Claude Channels -- helper poll 750ms/子 ------------+       + PTY -> Claude / shell / Codex UI
Claude hook     -- Node helper -> Unix socket ------+       + Codex host -> app-server
                                                           + transcript補完 2s/子
                                                           + provider title/history refresh
SwiftUI MainActor -> SwiftTerm parser/feed (8KiB yield)
                 -> CEF external message pump (10ms timer)
```

| 経路/資源 | 現行コード根拠 | スケール特性と残存問題 |
|---|---|---|
| 全state | `server.ts:254`, `store.ts:87`, `Models.swift:203` | 毎秒全projects/workspaces/terminalsをSQL→JSON→HTTP→decode。変更なしUI代入の抑制はあるが転送/parseは残る |
| terminal output | `NativeTerminal.swift:240`, `store.ts:97` | visible60ms、background500ms、more時10ms。各readで全pending outputをflush。`data`と`chunks`に同じ文字列が入り応答bytes増幅。backgroundも端末応答/画面状態のため処理が必要 |
| 永続化 | `store.ts:12-24,97-110` | 16ms/256chunks/256KiBでbatch、WAL/FULL維持。metadata put/read/resizeが途中flush。同期COMMIT/busy_timeout5sはevent loopを止め得る。件数制限はbyte制限ではなく単一巨大chunk、失敗時の蓄積は別途上限設計が必要 |
| Claude lifecycle | `terminals.ts:101`, `claude-completion.ts`, `agent-activity-hook.mjs` | working/waitingのみ最大512KiBの末尾read+JSON parseを2秒毎。10子で最大約2.5MiB/s読取・parse（全子該当時）。inode/size/mtime/ctimeとturn/session fenceあり、更新なしでも末尾再読取 |
| hooks | `agent-activity.ts:76,118` | 現行helper5s/config10s、socket idle1s。旧800ms/1sとは違う。各hookでNode起動。イベント数に比例するprocess spawnと永続化が残る |
| Channels | `supervision-mcp.mjs:130`, `agents.ts:126` | 子ごと750ms poll、重複inflight防止あり。`channel()`はagents全件scan。10子約13.3 req/s、履歴数MでO(子数×M)。probe60s、実deliveryは先にworkingへ保存して応答する |
| task_wait | `supervision-mcp.mjs:102`, `server.ts:304` | 750msに全agents（summary/reports/pendingも含む）を取得。revision取得にもstore.state()経由で別表の全読込 |
| queue | `server.ts:272-290`, `agents.ts` serial | GitHub/remote workspace/localを分けたがlocalは共有promise queue。上限・実行前deadline・client abortの伝搬が不足。遅いlocal操作にinput等が列待ち |
| タイトル | `session-names.ts:28-79` | 3s間隔/inflight共有。stateはawaitしなくなったがprovider history scan、Codex SQLite readOnly/busy50msは同じprocess。async関数でも同期部分は隔離されない |
| 子孫所有 | `codex-host.mjs:8,28`, `terminals.ts:146-205` | hostごと250msで全psをspawnして子孫PGID追跡。10 Codexなら最大40ps/s（Claude10子に直接適用しない）。stdin EOFでowner消失検知、TERM→1.5s KILL。stopWorkspaceに子孫再探索・5s終了確認あり |
| CEF/UI | `ChromiumBridge.mm:165`, `NativeTerminal.swift`, `Models.swift:224` | 10ms=100 timer fires/sのpump。MainActorでparse/feed/描画/HTTP後処理が競合し得る。8KiB cooperative yield・同一state更新抑制は現行にもある |
| 診断/電源 | `diagnostics.ts`, `Diagnostics.swift`, `AgentSleep.swift` | daemon20ms eventloop monitor＋10s集計、app1s heartbeat。診断queue256上限はdrop数非記録。sleep制御はユーザー設定による別機能、今回有効状態/電力量は未取得 |

HTTPの概算だけでも10端末（visible1+background9）約34.7req/s、Channels約13.3、state1、browser5で約54req/s。notifications、task_wait、Git等は追加。これはソース上の上限寄り定常モデルであり、実測req/sやOS起床数とは異なる。

## 観測: 何が実際に起きたか

診断集計の範囲（UTC、ローテーション保持分）:

| build | 確認できた期間 | native `-1001` output/state/input | UI hang |
|---|---|---:|---:|
| 57 | 10/28 13:27〜10/29 03:32 | 241 / 38 / 5 | 44 |
| 60 | 10/29 03:32〜08:14 | 3661 / 194 / 20 | 25 |
| 62 | 10/29 08:14〜08:26 | 0 / 0 / 0 | 0 |

build60にはgit196、usage14、resize11、notifications8のtimeoutもある。read成功は常時記録していないため**timeout率の分母がない**。上表を全要求の失敗率に換算しない。build間で観測時間・active子数・作業内容・外乱が異なるため、件数差から改善率も算出しない。

daemonの10秒窓の統計（窓ごとのp99をさらに集計した値で、全リクエストのp99ではない）:

| 期間 | 窓数 | eventloop p99窓値の中央値 / 95percentile | 全窓max |
|---|---:|---:|---:|
| build62起動前1時間 | 306 | 49.3 / 1367.3ms | 376078ms |
| build62起動後約12分 | 75 | 32.1 / 192.0ms | 1495ms |

睡眠/復帰とawake中のstallは別現象として扱う。既存ログにはsleep/wake境界の対照がなく、過去の非常に長い窓はOS sleep、CPU starvation、paging、同期処理を分離できていない。未分類窓をawake-stall分位値/SLO判定へ混入させない。次の試験ではOS sleep/wake event、wall clock、sleepを含むcontinuous clockと含まないuptimeを同時記録し、awake-only／復帰直後／sleep-overlapの3集合に分ける。loop monitorの値単独でSQLiteが376秒止めたとは言えない。現行でも1.5s級の遅延は観測され、hook/socketやbrowser2s deadlineには余裕が小さい。

read-only `proc_pid_rusage` 10.08秒標本: app/daemonのrootとその子孫73プロセス。daemonはCPU約6.4%（1core=100%）、RSS99.8MiB、interrupt wakeups約122.6/s、disk read6.56MiB/write9.91MiB。nativeはCPU約45.3%、RSS132.1MiB、interrupt wakeups約121.6/s、disk read36.8MiB。CPU timeはMach ticksをtimebase125/3でnsへ換算。package idle wakeupsはこの窓で0だが、ホストがbusyなので省電力の証拠ではない。CLI孫やテストhelperも含む稼働中標本で、idle benchmarkではない。短命ps/hookは標本間に消えるのでプロセス数は過少になり得る。RSS合計は共有pageを重複計上するため全体メモリとは扱わない。

別時点のtopではnative31.1%/daemon1.4%を観測。ホスト16GiB/8CPU、約6.6GiB compressor、swapin/outの**標本間増分**もあった。単なる累積swap量ではないが、Chromium拡張担当が同時にビルド/検証中であり、他アプリ・他タスクも稼働していた。これはCPU・メモリ・disk・energy測定の明示的な外乱で、時刻別の厳密な除去はできていない。neuraOS単独の原因帰属はできない。電池残量差、Watt、GPU、thermal、idle条件は未計測。CPU秒/起床/s/IO bytesをenergy proxyとして使用する。

最新3件のNeuraOS系crashを分類: build51のArray/Binding subscript `EXC_BREAKPOINT`、別browser smokeとdownloadtestのbuild0 crash。build62のcrash証拠はこの確認集合にない。過去Binding crashを今回のdaemon timeoutの原因に混同しない。

## “The request timed out.” の層と連鎖

| 層 | deadline / 表出 | 確認・未確認 |
|---|---|---|
| native URLSession | 一般15s、GET GitHub180s/checks90s、workspace/GitHub mutation240s、browser native poll2s | `Models.swift:82-121` のNSError codeを記録。`model.report(error.localizedDescription)`の表示経路。多数の-1001はFoundation timedOutに一致。全ユーザー目撃をこの経路と断定はしない |
| daemon HTTP/eventloop | Fastify独自の処理deadline設定なし | 接続済でもsync DB、JSON、GC、OS starvationで応答できない。queue waitと実行をoperation.received/executingで区別可能だがreadのstage traceがない |
| local操作queue | 外側native15s/240s、MCP250sと内側処理のbudget不統一 | timed outしたclientのqueued mutationが後で実行される可能性。操作IDで重複を防ぐがnative再操作は新UUIDになる。timeout=未実行ではない |
| MCP helper | fetch AbortSignal250s、task_wait750ms poll | helperは独自エラー文字列。CLI側tool deadlineはこのコードからは決まらない。全state/list readが別pollと重なる |
| Channels | 750ms cadence、probe60s | 応答前にpendingを除去/working保存。切断時は受信不明。exactly-once配信保証なし、盲目的再送は危険 |
| activity hook | helper5s、CLI設定10s、socket idle1s | 過去800msの欠落対策は存在。負荷でhelper起動が遅れること、socket closeはdurable application ACKではないことが残る |
| Codex/provider | CodexRPC12s (`codex-rpc.ts:53`)、Claude APIはCLI内部 | native15sと近い。provider API障害や429/retryの実ログは今回取得していない。Anthropic側timeoutが主因という証拠なし |

再試行連鎖は、output失敗後2s再開、state失敗後1s、Channels失敗後次tick、各子のpollが続く形。guardにより同じpollの重複は抑えるが、複数子の同期した再接続と一覧serializeが重なる。mutationの自動再送は現行も避けている。入力は送信前にpendingInputから取り除くため、応答不明時に安全な再送を自動判断できない。

原因候補の優先順位:

1. **強い候補**: eventloop停滞＋共有同期DB、FULL commit、全履歴read/parse、queue head-of-line。ログにloop遅延、実装に同期区間がある。特定commitのstack/time attributionは未取得。
2. **独立した強い候補**: UI/端末処理・CEF pump・メモリ圧迫。UI hang/高CPUと全体pagingがある。CEF単独の時間割合は未確認。
3. **増幅要因**: per-child polling、title/transcript scan、hook process spawn、Codex host ps。定周期は確定、実電力量への寄与率は未確認。
4. **未確認**: CLI/provider API timeout、network outage、SQLite外部writer競合、10子時のCLI個別RSS分布。過去負荷と同じ条件のtraceが必要。

## 独立合成検証

`node scripts/native/benchmark-architecture.mjs` は現Storeをimportし、worktree内の使い捨てSQLiteとloopback port0、別workerのHTTP clientを使用。子1/5/10/20、約1000byte/chunk、10ms毎/子、各5秒、visible1は60ms、他500ms、state1s。実課金agent/PTY/CEF/Fastify/Channelsは起動しない。

| 子数 | 実chunk数 | HTTP p95 / p99 ms | timeout / 要求 | eventloop p99 ms | CPU ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 457 | 8.46 / 27.23 | 0 / 83 | 22.36 | 433 |
| 5 | 2345 | 4.26 / 5.43 | 0 / 122 | 11.84 | 374 |
| 10 | 4560 | 20.54 / 29.75 | 0 / 166 | 21.51 | 503 |
| 20 | 9160 | 20.22 / 23.08 | 0 / 256 | 15.05 | 850 |

保存全rowの連番・件数でloss0/duplicate0を確認。DBをclose/reopenして全row数とterminal別cursor paginationの全文一致も検証した（正常再開でありcrash復旧試験ではない）。これは保存順序でありUIでの重複なしの証明ではない。1000ms deadline、表は正常再開検証を追加した最終実行の短い1回ずつの探索標本。初回探索では20子p99約119msも観測しており、他作業が稼働するホストでのばらつきは大きい。producerも同loopなのでstall時に生成率が落ちるcoordinated omissionがある。実chunk数を必ず併記した。clientも1inflight/streamで、総合SLO試験の代替ではない。process CPUはclient worker込み、rssは順次試験のprocess値、fsWrites=0はmacOSでこのcounterが役に立たないので「disk IOゼロ」と解釈しない。

既存 `benchmark-output.mjs` も再実行: 10terminal/2000chunks/各5回、median unbatched296.7ms → batched18.7ms。過去274→16msと同方向だが、単発burstの改善でしかない。Node/TSを直ちに捨てる根拠にはならず、10実Claudeの成功証明にもならない。

## harnessの再実行と安全範囲

このworktreeのrepo rootで実行（Node24、Python3/macOS Command Line Toolsが前提）。既存の証拠JSONを上書きしないよう別ファイル名で保存する。supervisorによる独立再実行が進行中のため、この文書改訂ではharnessを変更/再起動せず、その一時DBも触っていない。

```sh
node scripts/native/benchmark-architecture.mjs > /tmp/neura-architecture-review.json
node scripts/native/benchmark-output.mjs > /tmp/neura-output-review.json
python3 scripts/native/sample-architecture.py > /tmp/neura-process-review.json
```

- `benchmark-architecture`: 通常約20–30秒（4点×5秒＋起動/終了/検証、負荷時は延長）。worktreeの`docs/architecture-evidence/tmp-*`へ独立DBを作り、127.0.0.1のOS割当port0と自分のworkerだけを使用。正常時/例外finallyで自分のserver/worker/DBをcloseして自分の一時directoryを削除。実daemon・実DB・token・外部providerには接続しない。強制killなら一時directoryが残り得るので、別の実行が使用中のdirectoryを削除しない。
- `benchmark-output`: 通常数秒（2mode×5回、disk/外乱で延長）。OS tmpに独立SQLite、2000chunk/10terminalのburst。実CLI起動なし、実DBアクセスなし。自分のDBだけをcleanupする。
- `sample-architecture`: 約10秒＋process一覧取得。`ps`のPID/PPID/実行ファイル名とread-only `proc_pid_rusage`を使う。argv/env/DB/credentialsを読まず、実プロセスへsignalを送らない。Mach timebaseを出力し、CPU timeの換算を可能にする。実際のactive子数を仕事状態から判定する機能はない。

いずれも実10Claudeのend-to-end試験やbattery testではない。最初の2本自身がCPU/IO負荷になるため、process/energy baselineと同時に走らせない。短時間HTTP harnessはFastify/PTY/MCP/CEFや固定rate独立producerを実装していないため、上記のscaling sweep用の最終試験器は別途必要。再実行の結果が違えば外乱・throughput・生成数とともに比較し、最小latencyだけを採用しない。

## 追加の一次資料と未確認事項

- [Apple timeoutIntervalForRequest](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest?language=objc): inactivity timeoutの意味を保持し、総operation deadlineは別に定義する。単に15s→250sへ延長して障害を隠さない。
- [Apple timedOut](https://developer.apple.com/documentation/foundation/urlerror/timedout)、[XPC](https://developer.apple.com/documentation/xpc): web取得はJS/Markdown制約で本文を取得できなかった部分あり。XPCの性能優位を未検証の事実として扱わない。
- [Claude hooks公式](https://code.claude.com/docs/en/hooks): timeout/lifecycleはCLI版依存。現在の5s/10sはneuraOS側設定で、公式defaultとは区別。Channels受信成功と会話完了を同一視しない。
- 現行appのCPUがCEF/SwiftTerm/SwiftUIのどこへ分布するか、CLI10子のピークRSS・fork頻度、API retry、長期output/event/operation retention、DB checkpoint stall、wake復帰との相関は未確定。これらを断定するには追加の統制測定が必要であり、今回の合成比較から推測しない。

本検討の変更はこの文書、集計JSON、独立harnessのみ。実際のアーキテクチャ変更、PR公開、merge、releaseは行っていない。
