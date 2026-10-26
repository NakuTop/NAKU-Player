// Deterministic browser-contract check for the JS embedded in the Dart module.
// Run: node scripts/test_home_display_bridge.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const module = readFileSync(new URL('../lib/features/cinema/cinema_home_display_bridge.dart', import.meta.url), 'utf8');
const source = module.match(/const cinemaHomeDisplayBridgeSource = r'''([\s\S]*?)''';/)?.[1];
assert.ok(source, 'the Dart raw string contains the bridge');
new vm.Script(source);

class Events {
  listeners = new Map();
  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(callback);
  }
  removeEventListener(name, callback) { this.listeners.get(name)?.delete(callback); }
  dispatchEvent(event) { for (const callback of [...this.listeners.get(event.type) || []]) callback(event); return true; }
  listenerCount() { return [...this.listeners.values()].reduce((sum, list) => sum + list.size, 0); }
}

function browser(path = '/display', origin = 'https://between-us-home.pages.dev', options = {}) {
  let now = 0, nextId = 1;
  const jobs = new Map(), reports = [], requested = [], observers = [];
  const observations = { closest: 0, dimensions: 0, attributes: 0 };
  const window = new Events(), document = new Events();
  const location = {};
  const setUrl = (value) => {
    const url = new URL(value, location.href || origin);
    Object.assign(location, { href: url.href, origin: url.origin, pathname: url.pathname });
  };
  setUrl(origin + path);
  Object.assign(document, {
    hidden: false, readyState: 'complete', images: [],
    fonts: { ready: options.fonts || Promise.resolve() },
    querySelector: () => options.noLoginForm ? null : {},
  });
  class WebGL {
    constructor(earth = true) {
      this.drawingBufferWidth = 1280; this.drawingBufferHeight = 720;
      this.canvas = {
        get clientWidth() { observations.dimensions++; return 1280; },
        get clientHeight() { observations.dimensions++; return 720; },
        closest() {
          observations.closest++;
          return earth ? { getAttribute() { observations.attributes++; return options.textureTier || '4K'; } } : null;
        },
        getAttribute() { observations.attributes++; return null; },
      };
    }
    drawElements(...args) { if (this.drawError) throw this.drawError; this.drawArgs = args; return 'draw-return'; }
    drawArrays(...args) { return this.drawElements(...args); }
    bindFramebuffer() { return 'framebuffer-return'; }
    texImage2D(...args) { if (this.uploadError) throw this.uploadError; this.uploadArgs = args; return 'upload-return'; }
    texSubImage2D(...args) { this.uploadArgs = args; return 'sub-upload-return'; }
  }
  class WebGL2 extends WebGL {}
  const originalDraw = WebGL.prototype.drawElements, originalUpload = WebGL.prototype.texImage2D;
  const history = {
    pushState(_state, _title, value) { if (this.failure) throw this.failure; if (value) setUrl(value); return 'history-return'; },
    replaceState(_state, _title, value) { if (value) setUrl(value); return 'replace-return'; },
  };
  const originalPush = history.pushState;
  const originalFetch = function(input) {
    requested.push(input);
    const result = options.fetch ? options.fetch(input) : Promise.resolve({
      status: 200,
      get json() { throw new Error('response bodies must not be inspected'); },
      get text() { throw new Error('response bodies must not be inspected'); },
    });
    window.lastFetchResult = result; return result;
  };
  Object.assign(window, {
    window, top: window, document, location, history, fetch: originalFetch,
    performance: { now: () => now }, URL, Promise, console,
    Event: class { constructor(type) { this.type = type; } },
    WebGLRenderingContext: WebGL, WebGL2RenderingContext: WebGL2,
    setTimeout(fn, delay = 0) { const id = nextId++; jobs.set(id, { at: now + delay, fn }); return id; },
    clearTimeout(id) { jobs.delete(id); },
    requestAnimationFrame(fn) { const id = nextId++; jobs.set(id, { at: now + 16, fn }); return id; },
    cancelAnimationFrame(id) { jobs.delete(id); },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; observers.push(this); }
      observe() {}
      disconnect() { this.disconnected = true; }
    },
    flutter_inappwebview: options.noNativeBridge ? null : { callHandler(name, state) {
      reports.push({ name, state: JSON.parse(JSON.stringify(state)) }); return Promise.resolve();
    } },
  });
  const context = vm.createContext(window);
  vm.runInContext(source, context);
  async function advance(milliseconds) {
    const end = now + milliseconds;
    await Promise.resolve(); await Promise.resolve();
    let iterations = 0;
    while (true) {
      const next = [...jobs.entries()].filter(([, job]) => job.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      assert.ok(++iterations < 2000, 'bridge timers remain bounded');
      jobs.delete(next[0]); now = next[1].at; next[1].fn(now);
      await Promise.resolve(); await Promise.resolve();
    }
    now = end; await Promise.resolve(); await Promise.resolve();
  }
  return { window, document, location, history, reports, requested, observers, observations, jobs, WebGL, WebGL2,
    originalDraw, originalUpload, originalPush, originalFetch, advance,
    last: () => reports.at(-1)?.state };
}

let passed = 0;
async function test(name, run) {
  await run(); passed += 1; process.stdout.write(`ok ${passed} - ${name}\n`);
}

await test('production origin only', async () => {
  const page = browser('/display', 'https://between-us-home.pages.dev.evil.example');
  assert.equal(page.window.__nakuHomeDisplay, undefined);
  assert.equal(page.WebGL.prototype.drawElements, page.originalDraw);
  assert.equal(page.reports.length, 0);
});

await test('login waits for fonts, visible images and two animation frames', async () => {
  let resolveFonts;
  const page = browser('/login?return_to=%2Fdisplay&access_token=secret#private', undefined,
    { fonts: new Promise(resolve => { resolveFonts = resolve; }) });
  page.document.images = [{ complete: false, getClientRects: () => [{}] }];
  await page.advance(500);
  assert.equal(page.last().phase, 'loading');
  resolveFonts(); page.document.images[0].complete = true;
  page.window.__nakuHomeDisplay.refresh();
  await page.advance(20);
  assert.equal(page.last().phase, 'loading');
  await page.advance(150);
  assert.equal(page.last().phase, 'ready');
  assert.equal(page.last().surface, 'login');
  assert.equal(page.last().href, 'https://between-us-home.pages.dev/login');
  assert.ok(!JSON.stringify(page.reports).includes('secret'));
  assert.equal(page.requested.length, 0);
  page.window.__nakuHomeDisplay.destroy();
});

await test('display needs its own uploaded texture, nonempty draw, and website data status', async () => {
  const page = browser();
  const starfield = new page.WebGL(false), earth = new page.WebGL2();
  starfield.texImage2D(0, 0, 0, 0, 0, { width: 8192, height: 4096 });
  starfield.drawElements(4, 3, 0, 0);
  await page.advance(500);
  assert.equal(page.last().firstDrawObserved, false);
  assert.equal(page.last().phase, 'loading');
  const promise = page.window.fetch('/api/display');
  assert.equal(promise, page.window.lastFetchResult, 'fetch returns its original promise');
  await promise;
  assert.equal(earth.texImage2D(0, 0, 0, 0, 0, { width: 8192, height: 4096 }), 'upload-return');
  earth.drawElements(4, 0, 0, 0);
  await page.advance(250);
  assert.equal(page.last().phase, 'loading', 'zero-element draw is not a rendered frame');
  assert.equal(earth.drawElements(4, 3, 0, 0), 'draw-return');
  await page.advance(250);
  assert.equal(page.last().phase, 'ready');
  assert.equal(page.last().firstDrawObserved, true);
  assert.equal(page.last().maxTextureUploadWidth, 8192);
  assert.equal(page.last().maxTextureUploadHeight, 4096);
  assert.equal(page.last().textureUploadsObserved, 1, 'inherited WebGL2 methods are observed only once');
  assert.equal(page.requested.length, 1, 'the bridge adds no requests');
  page.window.__nakuHomeDisplay.destroy();
});

await test('placeholder uploads stay loading until the reported base earth profile is uploaded', async () => {
  const page = browser(), earth = new page.WebGL();
  await page.window.fetch('/api/display');
  for (let i = 0; i < 8; i += 1) earth.texImage2D(0, 0, 0, 0, 0, { width: 16, height: 16 });
  for (let i = 0; i < 100; i += 1) earth.drawElements(4, 3, 0, 0);
  await page.advance(500);
  assert.equal(page.last().apiStatus, 200);
  assert.equal(page.last().drawCalls, 100);
  assert.equal(page.last().maxTextureUploadWidth, 16);
  assert.equal(page.last().phase, 'loading', 'placeholder draws do not establish the earth texture');
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  earth.drawElements(4, 3, 0, 0);
  await page.advance(500);
  assert.equal(page.last().textureTier, 4096, 'the website label is normalized');
  assert.equal(page.last().phase, 'ready', 'the legitimate 4K base need not wait for an optional 8K upgrade');
  page.window.__nakuHomeDisplay.destroy();
});

await test('readiness follows the actual supported 2K, 4K or 8K site profile', async () => {
  for (const [label, width] of [['2K', 2048], ['4K', 4096], ['8K', 8192]]) {
    const page = browser('/display', undefined, { textureTier: label }), earth = new page.WebGL();
    await page.window.fetch('/api/display');
    earth.texImage2D(0, 0, 0, 0, 0, { width: width / 2, height: width / 4 });
    earth.drawElements(4, 3, 0, 0);
    await page.advance(500);
    assert.equal(page.last().phase, 'loading', `${label} waits for its base dimensions`);
    earth.texImage2D(0, 0, 0, 0, 0, { width, height: width / 2 });
    earth.drawElements(4, 3, 0, 0);
    await page.advance(500);
    assert.equal(page.last().textureTier, width);
    assert.equal(page.last().phase, 'ready', `${label} can complete independently`);
    page.window.__nakuHomeDisplay.destroy();
  }
  const page = browser('/display', undefined, { textureTier: 'loading' }), earth = new page.WebGL();
  await page.window.fetch('/api/display');
  earth.texImage2D(0, 0, 0, 0, 0, { width: 8192, height: 4096 });
  earth.drawElements(4, 3, 0, 0);
  await page.advance(500);
  assert.equal(page.last().phase, 'loading', 'a texture elsewhere in the canvas cannot replace the loaded earth profile');
  page.window.__nakuHomeDisplay.destroy();
});

await test('original receiver, return values and thrown errors are preserved', async () => {
  const page = browser();
  const earth = new page.WebGL();
  const error = new Error('original native error');
  earth.uploadError = error;
  assert.throws(() => earth.texImage2D(0, 0, 0, 2, 2, 0, 0, 0, new Uint8Array(16)), value => value === error);
  earth.drawError = error;
  assert.throws(() => earth.drawElements(4, 3, 0, 0), value => value === error);
  page.history.failure = error;
  assert.throws(() => page.history.pushState({}, '', '/login'), value => value === error);
  assert.equal(page.last().textureUploadsObserved, 0);
  page.window.__nakuHomeDisplay.destroy();
});

await test('null texture allocation is not reported as an image upload', async () => {
  const page = browser(), earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 8192, 4096, 0, 0, 0, null);
  earth.drawElements(4, 3, 0, 0);
  await page.window.fetch('/api/display'); await page.advance(500);
  assert.equal(page.last().phase, 'loading');
  assert.equal(page.last().maxTextureUploadWidth, 0);
  earth.texSubImage2D(0, 0, 0, 0, 4096, 2048, 0, 0, new Uint8Array(4));
  earth.drawElements(4, 3, 0, 0);
  await page.advance(500);
  assert.equal(page.last().phase, 'ready');
  assert.equal(page.last().maxTextureUploadWidth, 4096);
  page.window.__nakuHomeDisplay.destroy();
});

await test('offscreen framebuffer draws do not establish a visible earth frame', async () => {
  const page = browser(), earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  assert.equal(earth.bindFramebuffer(0x8D40, {}), 'framebuffer-return');
  earth.drawElements(4, 3, 0, 0);
  await page.window.fetch('/api/display'); await page.advance(500);
  assert.equal(page.last().firstDrawObserved, false);
  earth.bindFramebuffer(0x8CA9, null);
  earth.drawElements(4, 3, 0, 0);
  await page.advance(500);
  assert.equal(page.last().phase, 'ready');
  page.window.__nakuHomeDisplay.destroy();
});

await test('steady animation does not continuously message native code', async () => {
  const page = browser(), earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  earth.drawElements(4, 3, 0, 0);
  await page.window.fetch('/api/display'); await page.advance(500);
  const count = page.reports.length;
  for (let i = 0; i < 60; i += 1) { earth.drawElements(4, 3, 0, 0); await page.advance(16); }
  assert.equal(page.reports.length, count);
  page.window.__nakuHomeDisplay.destroy();
});

await test('steady WebGL animation does not query layout or texture labels per draw', async () => {
  const page = browser(), earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  earth.drawElements(4, 3, 0, 0);
  await page.window.fetch('/api/display'); await page.advance(500);
  assert.equal(page.last().phase, 'ready');
  const before = { ...page.observations }, reports = page.reports.length;
  for (let frame = 0; frame < 120; frame++) {
    for (let object = 0; object < 30; object++) earth.drawElements(4, 3, 0, 0);
    await page.advance(8.333);
  }
  assert.deepEqual(page.observations, before,
    '3600 steady draw calls add no layout or texture-label reads');
  assert.equal(page.reports.length, reports, 'steady rendering adds no native messages');
  earth.texImage2D(0, 0, 0, 0, 0, { width: 8192, height: 4096 });
  earth.drawElements(4, 3, 0, 0); await page.advance(250);
  assert.equal(page.last().maxTextureUploadWidth, 8192,
    'an optional high-resolution upload remains observable after readiness');
  page.window.__nakuHomeDisplay.destroy();
});

await test('loading coalesces layout observations across multiple WebGL draws', async () => {
  const page = browser(), earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 0, 0, { width: 16, height: 16 });
  await page.window.fetch('/api/display');
  const before = { ...page.observations };
  for (let draw = 0; draw < 3600; draw++) earth.drawElements(4, 3, 0, 0);
  assert.deepEqual(page.observations, before, 'draw hooks never synchronously read layout');
  await page.advance(150);
  assert.ok(page.observations.closest - before.closest <= 2, 'one scheduled check observes the canvas');
  assert.equal(page.last().drawCalls, 3600);
  assert.equal(page.last().phase, 'loading', 'coalescing cannot complete placeholder textures');
  page.window.__nakuHomeDisplay.destroy();
});

await test('a higher-resolution upload still needs a subsequent visible draw', async () => {
  const page = browser(), earth = new page.WebGL();
  await page.window.fetch('/api/display');
  earth.texImage2D(0, 0, 0, 0, 0, { width: 16, height: 16 });
  earth.drawElements(4, 3, 0, 0); await page.advance(500);
  assert.equal(page.last().phase, 'loading');
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  await page.advance(500);
  assert.equal(page.last().phase, 'loading', 'an upload alone is not displayed content');
  assert.equal(page.last().maxTextureUploadWidth, 16);
  earth.drawElements(4, 3, 0, 0); await page.advance(500);
  assert.equal(page.last().phase, 'ready');
  assert.equal(page.last().maxTextureUploadWidth, 4096);
  page.window.__nakuHomeDisplay.destroy();
});

await test('authorization status revocation never reports an old ready state', async () => {
  let status = 200;
  const page = browser('/display', undefined, { fetch: () => Promise.resolve({ status }) });
  const earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  earth.drawElements(4, 3, 0, 0);
  await page.window.fetch('/api/display'); await page.advance(500);
  assert.equal(page.last().phase, 'ready');
  status = 401;
  await page.window.fetch('/api/display'); await page.advance(500);
  assert.equal(page.last().phase, 'loading'); assert.equal(page.last().apiStatus, 401);
  page.window.__nakuHomeDisplay.destroy();
});

await test('only exact same-origin display status is observed', async () => {
  const page = browser(), earth = new page.WebGL();
  earth.texImage2D(0, 0, 0, 0, 0, { width: 4096, height: 2048 });
  earth.drawElements(4, 3, 0, 0);
  await page.window.fetch('/api/auth/login');
  await page.window.fetch('/api/display/weather?scope=all');
  await page.window.fetch('https://other.example/api/display');
  await page.advance(500);
  assert.equal(page.last().apiObserved, false);
  assert.equal(page.last().phase, 'loading');
  page.window.__nakuHomeDisplay.destroy();
});

await test('timeouts remain loading, and hidden time does not count as active waiting', async () => {
  const page = browser();
  page.window.__nakuHomeDisplay.setVisible(false);
  await page.advance(60_000);
  assert.equal(page.last().waiting, false);
  let resumedOnline = 0, resumedVisibility = 0;
  page.window.addEventListener('online', () => { resumedOnline += 1; });
  page.document.addEventListener('visibilitychange', () => { resumedVisibility += 1; });
  page.window.__nakuHomeDisplay.setVisible(true);
  await page.advance(100);
  assert.equal(page.last().waiting, false);
  assert.equal(page.document.hidden, false, 'native visibility does not redefine document.hidden');
  assert.equal(resumedOnline, 1); assert.equal(resumedVisibility, 1);
  await page.advance(30_000);
  assert.equal(page.last().phase, 'loading'); assert.equal(page.last().waiting, true);
  page.window.__nakuHomeDisplay.destroy();
});

await test('SPA navigation reports a fresh loading phase then login readiness', async () => {
  const page = browser();
  assert.equal(page.history.pushState({}, '', '/login?return_to=%2Fdisplay'), 'history-return');
  assert.equal(page.last().phase, 'loading'); assert.equal(page.last().surface, 'login');
  await page.advance(250);
  assert.equal(page.last().phase, 'ready');
  assert.equal(page.last().apiObserved, false);
  page.window.__nakuHomeDisplay.destroy();
});

await test('late native bridge receives the pending state', async () => {
  const page = browser('/login', undefined, { noNativeBridge: true });
  await page.advance(250);
  page.window.flutter_inappwebview = { callHandler(name, state) { page.reports.push({ name, state }); } };
  page.window.dispatchEvent({ type: 'flutterInAppWebViewPlatformReady' });
  assert.equal(page.last().phase, 'ready');
  assert.equal(page.reports[0].name, 'nakuHomeDisplayState');
  page.window.__nakuHomeDisplay.destroy();
});

await test('destroy restores prototypes, fetch and history, and cancels work', async () => {
  let finish;
  const page = browser('/display', undefined, { fetch: () => new Promise(resolve => { finish = resolve; }) });
  const request = page.window.fetch('/api/display');
  page.window.__nakuHomeDisplay.destroy();
  const reportCount = page.reports.length;
  assert.equal(page.WebGL.prototype.drawElements, page.originalDraw);
  assert.equal(page.WebGL.prototype.texImage2D, page.originalUpload);
  assert.equal(page.window.fetch, page.originalFetch);
  assert.equal(page.history.pushState, page.originalPush);
  assert.equal(page.window.__nakuHomeDisplay, undefined);
  assert.equal(page.jobs.size, 0);
  assert.equal(page.document.listenerCount(), 0);
  assert.equal(page.window.listenerCount(), 0);
  assert.ok(page.observers.every(observer => observer.disconnected));
  finish({ status: 200 }); await request; await page.advance(60_000);
  assert.equal(page.reports.length, reportCount, 'late website fetch cannot revive a destroyed bridge');
});

process.stdout.write(`${passed} bridge contracts passed.\n`);
