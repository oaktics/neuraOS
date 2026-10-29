# Concurrent agent performance

Terminal output is persisted in ordered batches: 16 ms, 256 chunks, or 256 KiB,
whichever is reached first. Reads, resize markers, metadata mutations, deletion,
and orderly shutdown flush the tail. SQLite remains WAL + synchronous=FULL.
An abrupt process/OS failure can lose the unflushed tail (the timer is a scheduling
target, not a hard wall-clock guarantee). Failed flushes retain data for retry;
normal disk failure handling remains applicable.

The macOS renderer feeds at most 8 KiB between cooperative yields, preserving
UTF-8 parser state and resize order. Background emulators still consume output:
stopping them entirely would delay terminal protocol replies and lose live screen
state. Replay tests compare the resulting screen with uninterrupted playback.

State polling does not await provider title lookups. Titles appear on a subsequent
poll; a slow provider lookup must not masquerade as a disconnected daemon.

Every ten seconds, rotated local diagnostics include event-loop p99/max delay,
utilization, RSS and used JS heap. No terminal content, paths or credentials are
included. Compare these metrics with macOS memory pressure and app ui.hang events
when diagnosing concurrent sessions; swap usage alone is not proof of active
thrashing, and idle measurements cannot explain a past incident conclusively.

## Reproducible storage benchmark

Run `node scripts/native/benchmark-output.mjs` with Node 24. This uses temporary
SQLite databases, ten terminal IDs and 2,000 chunks, five runs per mode, and checks
persisted row counts. It compares the former per-chunk FULL transaction with the
batched path. It does not launch paid agents or access the application database.

On the development Mac, observed medians were 274 ms unbatched and 16 ms batched.
Individual batched runs ranged from 6 to 221 ms under concurrent machine load.
These are storage-burst timings, not whole-app latency or proof that ten live
Claude sessions fit within 16 GB. Re-run on the target machine and use the new
telemetry for sustained workload evidence.
