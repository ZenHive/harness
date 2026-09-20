import { chromium } from '../../.harness/browser/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';

const port = process.env.INSIGHTS_BROWSER_PORT || '44045';
const output = 'docs/verification/run-insights/task-445';
await mkdir(output, { recursive: true });
const server = spawn('mix', ['run', 'test/browser/run_insights_server.exs'], {
  env: { ...process.env, MIX_ENV: 'test', INSIGHTS_BROWSER_PORT: port },
  detached: true, stdio: ['pipe', 'pipe', 'pipe']
});
let log = '';
server.stdout.on('data', chunk => { log += chunk; });
server.stderr.on('data', chunk => { log += chunk; });
const waitFor = async (text) => {
  const deadline = Date.now() + 30000;
  while (!log.includes(text)) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(`Server failed waiting for ${text}: ${log}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
};
let browser;
const observations = [];
let cleanupPromise;
const cleanup = () => cleanupPromise ||= (async () => {
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
  await writeFile('.harness/insights-browser.log', log);
})();
for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.once(signal, () => { void cleanup().finally(() => process.exit(code)); });
}
try {
  await waitFor('INSIGHTS_BROWSER_READY');
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  const capture = async (name, path, mobile) => {
    await page.setViewportSize(mobile ? { width: 390, height: 844 } : { width: 1440, height: 1000 });
    await page.goto(`http://127.0.0.1:${port}${path}`);
    await page.locator('.phx-connected').waitFor();
    await page.screenshot({ path: `${output}/${name}.png`, fullPage: true });
    const layout = await page.evaluate(() => ({ width: innerWidth, contentWidth: document.documentElement.scrollWidth }));
    if (layout.contentWidth > layout.width) throw new Error(`Horizontal overflow: ${name}`);
    observations.push({ name, ...layout });
  };
  for (const mobile of [false, true]) {
    const size = mobile ? 'mobile' : 'desktop';
    await capture(`${size}-paused`, '/harness/insights', mobile);
    await page.getByRole('link', { name: 'Configure observation' }).click();
    await page.locator('#insights-settings').waitFor();
    await page.locator('#insights-enabled').focus();
    await page.keyboard.press('Tab');
    if (await page.locator(':focus').getAttribute('id') !== 'insights-cadence') throw new Error('Settings tab order failed');
    await capture(`${size}-settings`, '/harness/insights/settings', mobile);
    await page.selectOption('#insights-cadence', '1440');
    await page.getByRole('button', { name: 'Save observer settings' }).click();
    await page.getByRole('status').filter({ hasText: 'Observer settings saved' }).waitFor();
    await capture(`${size}-filtered-empty`, '/harness/insights?project=missing', mobile);
    await page.getByRole('link', { name: 'Clear filters' }).click();
    await page.getByRole('link', { name: 'Configure observation' }).waitFor();
  }
  server.stdin.write('populate\n');
  await waitFor('INSIGHTS_POPULATED');
  const id = log.match(/INSIGHTS_POPULATED (\S+)/)[1];
  for (const mobile of [false, true]) {
    const size = mobile ? 'mobile' : 'desktop';
    await capture(`${size}-populated`, '/harness/insights', mobile);
    await capture(`${size}-history`, `/harness/insights/${id}`, mobile);
    await page.locator('summary').first().focus();
    await page.keyboard.press('Enter');
    if (await page.locator('details[open]').count() !== 1) throw new Error('Keyboard excerpt toggle failed');
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: `${output}/${size}-excerpt.png`, fullPage: true });
  }
  server.stdin.write('error\n');
  await waitFor('INSIGHTS_ERROR_READY');
  await capture('desktop-error', '/harness/insights', false);
  await capture('mobile-error', '/harness/insights', true);
  if (errors.length) throw new Error(errors.join('\n'));
  await writeFile(`${output}/browser.json`, JSON.stringify({ observations, errors, keyboard: 'settings tab order and excerpt Enter toggle passed' }, null, 2));
} finally {
  await cleanup();
}
