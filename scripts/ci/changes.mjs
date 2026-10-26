import {execFileSync} from 'node:child_process';
import {appendFileSync, readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

// Only known documentation locations are exempt. Markdown fixtures elsewhere
// can affect application behavior and must still be tested.
export function docsOnly(paths) {
  return paths.length > 0 && paths.every(path =>
    /^[^/]+\.md$/.test(path) || path.startsWith('docs/') ||
    path === '.github/pull_request_template.md' || path.startsWith('.github/ISSUE_TEMPLATE/'));
}

export function needsChecks(eventName, event, git = args => execFileSync('git', args, {encoding: 'utf8'})) {
  if (!['push', 'pull_request'].includes(eventName)) return true;
  const base = eventName === 'pull_request' ? event.pull_request.base.sha : event.before;
  const head = eventName === 'pull_request' ? event.pull_request.head.sha : event.after;
  if (!base || /^0+$/.test(base) || !head) return true;
  if (![base, head].every(sha => /^[a-f0-9]{40}$/.test(sha))) throw new Error('Invalid event SHA');
  // PRs compare their changes since the merge base; pushes compare both trees.
  // Disable rename detection so a code -> docs move cannot bypass validation.
  const range = eventName === 'pull_request' ? [`${base}...${head}`] : [base, head];
  const paths = git(['diff', '--name-only', '--no-renames', '-z', ...range, '--']).split('\0').filter(Boolean);
  return !docsOnly(paths);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const required = needsChecks(process.env.GITHUB_EVENT_NAME, event);
  appendFileSync(process.env.GITHUB_OUTPUT, `required=${required}\n`);
  console.log(required ? 'Code checks required' : 'Documentation only: native checks omitted');
}
