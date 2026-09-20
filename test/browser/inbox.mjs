import { chromium } from '../../.harness/browser/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';

const port = process.env.INBOX_BROWSER_PORT || '44038';
const output = '.harness/inbox-browser';
await mkdir(output, { recursive: true });
const server = spawn('mix', ['run', 'test/browser/inbox_server.exs'], {
  env: { ...process.env, MIX_ENV: 'test', INBOX_BROWSER_PORT: port },
  detached: true, stdio: ['pipe', 'pipe', 'pipe']
});
let log = '';
server.stdout.on('data', chunk => { log += chunk; });
server.stderr.on('data', chunk => { log += chunk; });
let browser;
let cleaning;
const cleanup = () => cleaning ||= (async () => {
  let exited;
  let timer;
  if (server.exitCode === null && server.signalCode === null) {
    exited = once(server, 'exit');
    process.kill(-server.pid, 'SIGTERM');
    timer = setTimeout(() => process.kill(-server.pid, 'SIGKILL'), 5000);
  }
  await browser?.close();
  await exited;
  clearTimeout(timer);
  await writeFile(`${output}/server.log`, log);
})();
for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.once(signal, () => { void cleanup().finally(() => process.exit(code)); });
}
try {
  const deadline = Date.now() + 30000;
  while (!log.includes('INBOX_BROWSER_READY')) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(`Server unavailable: ${log}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  for (const [name, width, height] of [['desktop', 1440, 1000], ['mobile', 390, 844]]) {
    server.stdin.write('populate\n');
    await page.setViewportSize({ width, height });
    await page.goto(`http://127.0.0.1:${port}/harness/inbox`);
    await page.getByRole('button', { name: 'Approve', exact: true }).waitFor();
    await page.locator('#inbox-navigation').filter({ hasText: 'Inbox 1' }).waitFor();
    if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error(`${name} overflow`);
    await page.screenshot({ path: `${output}/${name}.png`, fullPage: true });
    await page.getByRole('button', { name: 'Approve', exact: true }).focus();
    await page.keyboard.press('Enter');
    await page.getByText('No unresolved actions in this project scope.').waitFor();
    await page.locator('#inbox-navigation').filter({ hasText: 'Inbox 0' }).waitFor();
    await page.screenshot({ path: `${output}/${name}-empty.png`, fullPage: true });
  }
  server.stdin.write('error\n');
  await page.getByRole('alert').filter({ hasText: 'Inbox unavailable' }).waitFor();
  await page.locator('#inbox-navigation').filter({ hasText: '—' }).waitFor();
  if (errors.length) throw new Error(errors.join('\n'));
  await writeFile(`${output}/result.json`, JSON.stringify({ viewports: ['desktop', 'mobile'],
    keyboard: 'Approve with Enter', navigation: 'live counts and unavailable state', errors }, null, 2));
} finally {
  await cleanup();
}
