// Accessibility check: serves dist/ on a local port, loads the page in Chrome in both themes at desktop and
// mobile widths, and fails on any axe violation (WCAG 2.2 A/AA rules). Usage: npm run build && npm run a11y
import { chromium } from 'playwright-core';
import AxeBuilder from '@axe-core/playwright';
import { serve } from './serve.mjs';

const base = '/MacScreen';
const server = serve(0);
await new Promise((resolve) => server.on('listening', resolve));
const port = server.address().port;

const browser = await chromium.launch({ channel: process.env.CHROME_CHANNEL ?? 'chrome' });
let failures = 0;
for (const scheme of ['light', 'dark']) {
  for (const viewport of [{ width: 1280, height: 900 }, { width: 375, height: 812 }]) {
    const ctx = await browser.newContext({ colorScheme: scheme, viewport, reducedMotion: 'reduce' });
    const page = await ctx.newPage();
    await page.goto(`http://127.0.0.1:${port}${base}/`, { waitUntil: 'networkidle' });
    const { violations } = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice']).analyze();
    const label = `${scheme} ${viewport.width}px`;
    if (violations.length === 0) console.log(`ok   ${label}: no axe violations`);
    for (const v of violations) {
      failures++;
      console.log(`FAIL ${label}: ${v.id} (${v.impact}) ${v.help}`);
      for (const n of v.nodes.slice(0, 3)) console.log(`       ${n.target.join(' ')}`);
    }
    // Every in-page #link points at an element that exists.
    const broken = await page.evaluate(() => [...document.querySelectorAll('a[href^="#"]')]
      .map((a) => a.getAttribute('href')).filter((h) => h.length > 1 && !document.getElementById(h.slice(1))));
    if (broken.length) { failures++; console.log(`FAIL ${label}: broken anchors ${broken.join(', ')}`); }
    // No horizontal scroll on narrow screens.
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    if (overflow > 0) { failures++; console.log(`FAIL ${label}: horizontal overflow ${overflow}px`); }
    await ctx.close();
  }
}
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
