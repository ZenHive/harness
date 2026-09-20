import { chromium } from '../../.harness/browser/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { once } from 'node:events';

const port = process.env.QA_BROWSER_PORT || '44049';
const output = '.harness/qa-browser';
await mkdir(output, { recursive: true });
const root = await mkdtemp(resolve('.harness/qa-browser-fixture-'));
const database = `harness_qa_browser_${process.pid}`;
const env = { ...process.env, MIX_ENV: 'test', HARNESS_DB_NAME: database,
  HARNESS_LOG_LEVEL: 'warning', QA_BROWSER_PORT: port, QA_BROWSER_ROOT: root };
delete env.DATABASE_URL;
delete env.HARNESS_DATABASE_URL;
let log = '', server, browser, databaseCreated = false, cleanupPromise;
const children = new Set();
function launch(args) {
  const child = spawn('mix', args, { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  children.add(child);
  child.once('exit', () => children.delete(child));
  child.stdout.on('data', chunk => { log += chunk; });
  child.stderr.on('data', chunk => { log += chunk; });
  return child;
}
async function mix(args) {
  const child = launch(args);
  const [code] = await once(child, 'exit');
  if (code !== 0) throw new Error(`mix ${args.join(' ')} failed: ${log}`);
}
async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  process.kill(-child.pid, 'SIGTERM');
  const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 5000);
  await exited;
  clearTimeout(timer);
}
const cleanup = () => cleanupPromise ||= (async () => {
  await browser?.close();
  await Promise.all([...children].map(stop));
  if (databaseCreated) await mix(['ecto.drop', '--force']);
  await rm(root, { recursive: true });
  await writeFile(`${output}/server.log`, log);
})();
for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.once(signal, () => { void cleanup().finally(() => process.exit(code)); });
}
try {
  await mix(['ecto.create']);
  databaseCreated = true;
  await mix(['ecto.migrate']);
  server = launch(['run', 'test/browser/qa_server.exs']);
  const deadline = Date.now() + 30000;
  while (!log.includes('QA_BROWSER_READY')) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(`Isolated server unavailable: ${log}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [], observations = [];
  page.on('pageerror', error => errors.push(String(error)));
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    for (const [label, route] of [['overview', ''], ['project', '/qa-browser']]) {
      await page.goto(`http://127.0.0.1:${port}/harness/qa${route}`);
      await page.locator('[data-phx-main].phx-connected').waitFor();
      await page.getByRole('heading', { name: 'qa-browser', exact: true }).waitFor();
      if (label === 'overview') {
        await page.locator('#qa-project').focus();
        await page.keyboard.press('Tab');
        if (await page.locator(':focus').getAttribute('id') !== 'qa-status') throw new Error('Filter tab order failed');
        await page.locator('#qa-status').selectOption('passed');
        await page.getByText('No projects match these filters.').waitFor();
        await page.locator('#qa-status').selectOption('');
        await page.getByRole('heading', { name: 'qa-browser', exact: true }).waitFor();
      } else {
        await page.getByRole('button', { name: 'Read evidence' }).focus();
        await page.keyboard.press('Enter');
        await page.getByRole('heading', { name: 'Check outcomes supplied by the agent' }).waitFor();
        await page.getByRole('button', { name: 'Next evidence' }).waitFor();
      }
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.screenshot({ path: `${output}/${width}-${label}.png`, fullPage: true });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow) throw new Error(`Horizontal overflow at ${width} ${label}`);
      observations.push({ width, route, overflow });
    }
  }
  await page.locator('#qa-start').click();
  await page.getByRole('status').filter({ hasText: /QA job \d+ queued\./ }).waitFor();
  await page.locator('#qa-start').click();
  await page.getByRole('status').filter({ hasText: 'already active' }).waitFor();
  if (errors.length) throw new Error(errors.join('\n'));
  await writeFile(`${output}/results.json`, JSON.stringify({ observations, errors,
    keyboard: 'filter Tab and evidence Enter passed', actions: 'queue and duplicate acknowledgement passed' }, null, 2));
  console.log('QA browser checks passed: desktop/mobile, filtering, evidence, keyboard, queue actions and overflow.');
} finally {
  await cleanup();
}
