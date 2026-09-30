// Headless smoke test for the web demonstration build.
//
// A screenshot proves pixels were painted; it does not prove the app reached a
// usable screen rather than an error state. This script drives Chrome over the
// DevTools protocol, turns on Flutter's accessibility (semantics) tree so the
// rendered widgets appear in the DOM as text, and prints what is actually on
// screen.
//
// Usage:
//   node tools/web_smoke.mjs http://localhost:8080/ [expected substring]
//
// Exits non-zero when the expected substring is missing, so it can be used as a
// deploy gate: "the demo boots and shows the sign-in screen" rather than "the
// build uploaded".

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';

const CHROME_CANDIDATES = [
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
];

const url = process.argv[2] ?? 'http://localhost:8080/';
// The first paint of a fresh session is the worker PROVISIONING form, whose
// fields are the only widgets Flutter exposes to the accessibility tree before a
// worker exists. Reaching it means the browser database opened and answered the
// worker-count query: a store that failed to open renders an error card with no
// input fields at all, so this is a real gate rather than a liveness check.
const expected = process.argv[3] ?? 'Passcode';
const port = 9333;

const chromePath = CHROME_CANDIDATES.find((candidate) => existsSync(candidate));

if (!chromePath) {
  console.error('No Chrome/Chromium found; skipping the web smoke test.');
  process.exit(0);
}

const chrome = spawn(chromePath, [
  '--headless=new',
  '--disable-gpu',
  '--no-sandbox',
  '--hide-scrollbars',
  '--window-size=430,932',
  `--remote-debugging-port=${port}`,
  '--user-data-dir=' + process.env.TEMP + '/arogya-smoke-profile',
  url,
]);

let ws;
try {
  const target = await waitForTarget();
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  ws.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    const resolver = pending.get(message.id);
    if (resolver) {
      pending.delete(message.id);
      resolver(message);
    }
  });

  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const id = nextId++;
      pending.set(id, resolve);
      ws.send(JSON.stringify({ id, method, params }));
    });

  await send('Runtime.enable');

  // The Flutter view is created as soon as the engine boots, which happens well
  // before the first screen is usable.
  await waitFor("!!document.querySelector('flutter-view')", 45000);
  await delay(4000);

  // Flutter paints into a canvas, so text only reaches the DOM once the
  // semantics tree is switched on. The placeholder is the affordance Flutter
  // itself renders for a screen-reader user, so clicking it is the same path a
  // real assistive technology takes.
  let enable = 'no-placeholder';
  for (let attempt = 0; attempt < 20; attempt++) {
    enable = await evaluate(`
      (() => {
        const placeholder = document.querySelector('flt-semantics-placeholder');
        if (!placeholder) return 'no-placeholder';
        placeholder.click();
        return 'clicked';
      })()
    `);
    if (enable === 'clicked') break;
    await delay(1000);
  }
  console.log(`semantics: ${enable}`);

  // Give the app time to rebuild the tree with semantics enabled.
  await delay(5000);

  // Semantics nodes carry their text as aria-labels rather than as text nodes.
  const text = await evaluate(`
    (() => {
      const labelled = Array.from(document.querySelectorAll('[aria-label]'))
        .map((element) => element.getAttribute('aria-label'))
        .filter((value) => value && value.trim().length > 0);
      if (labelled.length > 0) return labelled.join('\\n');
      return document.body.innerText;
    })()
  `);

  async function waitFor(expression, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await evaluate(expression)) return true;
      await delay(500);
    }
    throw new Error(`timed out waiting for ${expression}`);
  }
  const title = await evaluate('document.title');
  console.log(`title: ${title}`);
  console.log('--- rendered text ---');
  console.log(text);
  console.log('---------------------');

  if (typeof text !== 'string' || !text.includes(expected)) {
    console.error(`FAIL: "${expected}" is not on screen.`);
    process.exitCode = 1;
  } else {
    console.log(`OK: the demo boots and shows "${expected}".`);
  }

  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    return result?.result?.result?.value;
  }
} catch (error) {
  console.error('smoke test error:', error);
  process.exitCode = 1;
} finally {
  try {
    ws?.close();
  } catch {}
  chrome.kill();
}

async function waitForTarget() {
  for (let attempt = 0; attempt < 40; attempt++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`);
      const targets = await response.json();
      const page = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page) return page;
    } catch {
      // Chrome is not listening yet.
    }
    await delay(500);
  }
  throw new Error('Chrome did not expose a debugging target in time.');
}
