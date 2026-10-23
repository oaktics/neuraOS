// Observational hook: never print a decision, prompt, tool arguments, or output.
// The CLI waits only for this bounded local delivery, not for UI polling.
import {createConnection} from 'node:net';
const timer = setTimeout(() => process.exit(0), 800);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  input += chunk;
  if (input.length > 1024 * 1024) process.exit(0);
});
process.stdin.on('error', () => process.exit(0));
process.stdin.on('end', () => {
  try {
    const payload = JSON.parse(input), event = {};
    for (const key of ['hook_event_name', 'session_id', 'transcript_path', 'agent_id', 'turn_id', 'tool_name', 'tool_use_id', 'source', 'notification_type']) {
      if (typeof payload[key] === 'string' && payload[key].length <= 4096) event[key] = payload[key];
    }
    const path = process.env.NEURA_ACTIVITY_SOCKET;
    if (!path) return process.exit(0);
    const socket = createConnection(path);
    socket.on('error', () => process.exit(0));
    socket.on('connect', () => socket.end(JSON.stringify(event) + '\n'));
    socket.on('close', () => {clearTimeout(timer); process.exit(0);});
  } catch {process.exit(0);}
});
