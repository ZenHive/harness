import { chromium } from '../../.harness/browser/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';

const port = process.env.MAINTENANCE_BROWSER_PORT || '44044';
const output = '.harness/maintenance-browser';
await mkdir(output, { recursive: true });
const env = { ...process.env, MIX_ENV: 'test', MAINTENANCE_BROWSER_PORT: port };
delete env.HARNESS_DATABASE_URL;
delete env.DATABASE_URL;
const server = spawn('mix', ['run', 'test/browser/maintenance_server.exs'], { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
let log = '';
server.stdout.on('data', chunk => { log += chunk; });
server.stderr.on('data', chunk => { log += chunk; });
let browser;
let cleanupPromise;
const cleanup = () => cleanupPromise ||= (async () => {
  let exited, timer;
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
  while (!log.includes('MAINTENANCE_BROWSER_READY')) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(`Isolated server unavailable: ${log}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  const observations = [];
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    for (const [label, route] of [['fleet', ''], ['repository', '/repositories/browser-fixture'], ['finding', '/findings/browser-finding']]) {
      await page.goto(`http://127.0.0.1:${port}/harness/maintenance${route}`);
      await page.locator('[data-phx-main].phx-connected').waitFor();
      await page.screenshot({ path: `${output}/${width}-${label}.png`, fullPage: true });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow) throw new Error(`Horizontal overflow at ${width} ${label}`);
      observations.push({ width, route, overflow });
      if (label === 'repository') {
        await page.locator('#maintenance-enabled').focus();
        await page.keyboard.press('Tab');
        if (await page.locator(':focus').getAttribute('id') !== 'maintenance-cadence') throw new Error('Settings tab order failed');
        await page.locator('#maintenance-cadence').fill('1440');
        await page.locator('#maintenance-model').selectOption('gpt-6-astra');
        await page.getByRole('button', { name: 'Save settings' }).click();
        await page.getByRole('status').filter({ hasText: 'Maintenance settings saved.' }).waitFor();
      }
    }
  }
  if (errors.length) throw new Error(errors.join('\n'));
  await writeFile(`${output}/results.json`, JSON.stringify({ observations, errors }, null, 2));
  console.log('Maintenance browser checks passed: desktop/mobile, settings, history, keyboard and overflow.');
} finally {
  await cleanup();
}
