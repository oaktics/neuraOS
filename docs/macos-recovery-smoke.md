# Daemon recovery and isolated UI smoke

The neuraOS app menu offers **Daemonを再起動…**, including while offline. The confirmation warns that agent work and terminals may be interrupted; Cancel performs no restart. One operation owns confirmation, launchctl and reconnection, so repeated menu actions cannot start concurrent restarts. Installed release bundles use `launchctl kickstart -k gui/<uid>/app.neuraos.daemon`; development/fixture bundles refuse to touch the normal LaunchAgent. Errors remain visible and the operation can be retried. Success requires a fresh authenticated, protocol-compatible state response and, when supported, a connected state stream. No existing terminal session is promised to survive a daemon restart.

Conversation HTTP/HTTPS links already route through the workspace's `openURL` handler and create a selected browser tab in that workspace. Codex and Claude use the same terminal delegate. Tab IDs rather than array positions identify navigation; agent tabs are retained. Other terminal link schemes remain rejected. The regression covers consecutive links after browser-tab deletion/reordering and separate workspace IDs.

## Browser smoke preflight

Build a disposable candidate with matching values, for example:

```sh
NEURA_APP_ID=com.neuraos.browser-smoke.local \
NEURA_APP_OUTPUT=/tmp/neura-browser-local.app \
NEURA_DEV_DATA_DIR=/private/tmp/neura-browser-local-data \
NEURA_DEV_PORT=44319 node scripts/native/build.mjs
NEURA_APP_OUTPUT=/tmp/neura-browser-local.app \
NEURA_DEV_DATA_DIR=/private/tmp/neura-browser-local-data \
NEURA_DEV_PORT=44319 node --import tsx scripts/native/chromium/browser-smoke.ts
```

Before creating data, a fixture server, daemon, CLI or app, the harness validates the candidate executable and Info.plist's bundle ID, data directory and endpoint. Data strings must match exactly, including `/tmp` versus `/private/tmp`, as required by the Swift guard. Mismatch errors name the field and redact non-fixture paths/URLs. Preflight success is not browser-operation success. `evidence.json` distinguishes app-ready, native-connection, initial-navigation and subsequent browser operations. Early app exit interrupts pending readiness/MCP waits and records code/signal. The Swift fixture also validates the endpoint in its generated configuration.

## Packaged UI phases

The guarded reliability entrypoint writes `ui-phases.jsonl` alongside the diagnostic report, writing each record directly to the kernel without buffered stdio or UI-thread fsync. Records contain only fixed phase IDs, start/complete, elapsed monotonic milliseconds, expected phase deadline and sheet iteration index. They do not contain view content or credentials.

Release smoke failure summaries include the last started/completed phase, expected deadlines, overall 30-second timeout, phase log, diagnostic report and sample paths. Existing sample capture and failure-directory retention remain enabled. Expected phase deadlines are diagnostic budgets; the outer harness enforces the overall timeout.

For deliberate interruption coverage, build a candidate with bundle ID `com.neuraos.reliability-smoke.<suffix>`, data `/private/tmp/neura-ui-phase-<suffix>` and endpoint `http://127.0.0.1:1`, then run:

```sh
NEURA_APP_OUTPUT=/tmp/isolated-candidate.app node scripts/native/release/ui-phase-regression.mjs
```

This sequential matrix stops each phase using `NEURA_UI_SMOKE_STALL_PHASE`, verifies the synchronized last-start record survives terminating the fixture's process group, then runs the normal success path. Only the guarded fixture reads that test control. It never registers/restarts LaunchAgents or uses normal profiles. Evidence is retained in the configured isolated directory. The matrix is separate from full signed release-runtime validation.
