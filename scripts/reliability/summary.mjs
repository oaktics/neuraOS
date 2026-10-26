import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

export function summarize(reports, now = Date.now()) {
  const events = new Map(), crashes = new Map();
  for (const report of reports) {
    for (const [name, log] of Object.entries(report.logs ?? {})) {
      if (!name.startsWith('app.')) continue; // Daemon events are correlation evidence, not extra user actions.
      for (const line of log.split('\n')) {
        try {
          const event = JSON.parse(line);
          if (!Number.isFinite(Date.parse(event.time))) continue;
          events.set(JSON.stringify(event), event);
        } catch { /* A truncated last line must not discard the entire report. */ }
      }
    }
    for (const crash of report.crashes ?? []) if (crash.incident_id) crashes.set(crash.incident_id, crash);
  }
  const rows = [];
  for (const [period, from, to] of [['current', now - 7 * 86400000, now], ['previous', now - 14 * 86400000, now - 7 * 86400000]]) {
    const builds = new Map();
    for (const event of events.values()) {
      const time = Date.parse(event.time);
      if (time < from || time >= to) continue;
      const build = event.build ?? 'unknown';
      if (!builds.has(build)) builds.set(build, []);
      builds.get(build).push(event);
    }
    for (const [build, values] of builds) {
      const starts = values.filter(e => e.event === 'operation.start');
      const ids = new Set(starts.map(e => e.operationId));
      const finished = values.filter(e => ids.has(e.operationId) && ['operation.success', 'operation.failure'].includes(e.event));
      const failures = finished.filter(e => e.event === 'operation.failure');
      const groups = new Map();
      for (const event of failures) groups.set(event.operation, (groups.get(event.operation) ?? 0) + 1);
      rows.push({period, build, observedSessions: new Set(values.filter(e => e.event === 'session.start').map(e => e.session)).size,
        cleanExits: values.filter(e => e.event === 'session.end').length,
        uncleanExits: values.filter(e => e.event === 'session.unclean').length,
        uiHangs: values.filter(e => e.event === 'ui.hang').length,
        operationsStarted: starts.length, operationsFinished: finished.length, failures: failures.length,
        failureRate: finished.length ? failures.length / finished.length : null,
        slowOperations: values.filter(e => e.event === 'operation.slow').length,
        topFailures: [...groups].sort((a,b) => b[1]-a[1]).slice(0,10)});
    }
  }
  return {generatedAt: new Date(now).toISOString(), coverage: 'Retained local logs only; rotation, missing reports and period boundaries can omit events. Unclean exit is not proof of a crash. Failure rate uses completed, traced user operations only.', crashReports: [...crashes.values()], rows};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length < 3) throw new Error('Usage: node scripts/reliability/summary.mjs report.json [report2.json ...]');
  const reports = await Promise.all(process.argv.slice(2).map(async path => JSON.parse(await readFile(path, 'utf8'))));
  process.stdout.write(JSON.stringify(summarize(reports), null, 2) + '\n');
}
