// Drives the running web app in a real (headless) browser as one of the six
// accounts, visits pages, and reports console errors, page errors and failed
// requests. Uses the locally installed Chrome, so nothing is downloaded.
//
//   npm run browser-check -- kilele analyst [/contacts /dashboard ...]
import { chromium } from 'playwright-core';
import { account, type BrandSlug, type Role } from './accounts.ts';

const [brand, role, ...paths] = process.argv.slice(2);
if (!brand || !role) throw new Error('usage: npm run browser-check -- <brand> <role> [paths...]');
const base = process.env.APP_URL ?? 'http://localhost:5173';
const acct = account(brand as BrandSlug, role as Role);
const pages = paths.length ? paths : ['/dashboard', '/contacts', '/campaigns', '/imports'];

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
const page = await context.newPage();
const problems: string[] = [];
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') problems.push(`[console.${m.type()}] ${m.text()}`); });
page.on('pageerror', (e) => problems.push(`[pageerror] ${e.message}\n${e.stack ?? ''}`));
page.on('response', (r) => { if (r.status() >= 400) problems.push(`[http ${r.status()}] ${r.request().method()} ${r.url()}`); });

try {
  await page.goto(`${base}/login`);
  await page.getByLabel('Email').fill(acct.email);
  await page.getByLabel('Password').fill(acct.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/b\/[^/]+\//, { timeout: 15_000 });
  console.log(`signed in -> ${new URL(page.url()).pathname}`);

  for (const p of pages) {
    const url = p.startsWith('/b/') ? p : `/b/${brand}${p}`;
    const before = problems.length;
    await page.goto(`${base}${url}`);
    await page.waitForLoadState('networkidle', { timeout: 20_000 }).catch(() => {});
    const heading = await page.locator('h1').first().textContent({ timeout: 5_000 }).catch(() => '(no h1)');
    const text = (await page.locator('main').first().innerText({ timeout: 5_000 }).catch(() => '')).slice(0, 300).replace(/\s+/g, ' ');
    console.log(`\n${url}  h1="${heading}"\n  ${text}`);
    for (const pr of problems.slice(before)) console.log(`  ${pr}`);
  }
} catch (e) {
  console.log('FAILED:', e instanceof Error ? e.message : e);
  for (const pr of problems) console.log(`  ${pr}`);
  console.log('page text:', (await page.locator('body').innerText().catch(() => '')).slice(0, 500));
} finally {
  await browser.close();
}
