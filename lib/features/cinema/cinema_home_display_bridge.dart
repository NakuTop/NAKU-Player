/// Only rendering observations cross this bridge. Website data requests,
/// authentication, image selection and adaptive quality remain website-owned.
const cinemaHomeDisplayBridgeHandlerName = 'nakuHomeDisplayState';

/// Inject at document start, for the main frame only.
///
/// `href` omits query/fragment values. Texture metrics describe completed WebGL
/// upload calls with observable source dimensions, not GPU error validation.
/// No pixels, response bodies, credentials or personal itinerary data are read.
const cinemaHomeDisplayBridgeSource = r'''
(() => {
  'use strict';
  if (window.top !== window || location.origin !== 'https://between-us-home.pages.dev') return;
  if (window.__nakuHomeDisplay) return;
  const restorers = [], listeners = [], contexts = new WeakMap();
  const handlerName = 'nakuHomeDisplayState';
  let destroyed = false, visible = true, timer = 0, frame = 0, observer = null;
  let generation = 0, navigation = '', startedAt = 0, pausedAt = null, ready = false, timedOut = false;
  let apiStatus = null, apiObserved = false, fontsReady = false, settling = false;
  let drawn = false, drawCalls = 0, uploadedWidth = 0, uploadedHeight = 0, uploads = 0;
  let textureTier = null, renderDpr = null, lastUploadAt = 0, lastSent = '', pendingReport = null;
  const clock = () => performance.now();
  const active = () => !destroyed && visible && !document.hidden;
  const route = () => location.pathname.replace(/\/+$/, '') || '/';
  const safeHref = () => location.origin + location.pathname;
  const finite = (value) => typeof value === 'number' && Number.isFinite(value) && value > 0;
  function listen(target, name, callback, options) {
    target.addEventListener(name, callback, options);
    listeners.push(() => target.removeEventListener(name, callback, options));
  }
  function patch(target, name, observe) {
    if (!target || typeof target[name] !== 'function') return;
    const original = target[name], descriptor = Object.getOwnPropertyDescriptor(target, name);
    function wrapped(...args) {
      const result = Reflect.apply(original, this, args);
      try { if (!destroyed) observe(this, args, result); } catch (_) {}
      return result;
    }
    try {
      Object.defineProperty(target, name, descriptor ? { ...descriptor, value: wrapped } : { value: wrapped, configurable: true, writable: true });
      restorers.push(() => {
        if (target[name] !== wrapped) return;
        if (descriptor) Object.defineProperty(target, name, descriptor);
        else delete target[name];
      });
    } catch (_) { /* Unsupported/non-configurable browser methods stay intact. */ }
  }
  function state() {
    const result = {
      href: safeHref(), phase: ready ? 'ready' : 'loading',
      surface: route() === '/display' ? 'display' : route() === '/login' ? 'login' : 'page',
      firstDrawObserved: drawn, drawCalls, textureUploadsObserved: uploads,
      maxTextureUploadWidth: uploadedWidth, maxTextureUploadHeight: uploadedHeight,
      apiObserved, apiStatus, waiting: timedOut,
    };
    if (textureTier !== null) result.textureTier = textureTier;
    if (renderDpr !== null) result.renderDpr = renderDpr;
    return result;
  }
  function send(force = false) {
    if (destroyed) return;
    // Draw counters are diagnostic snapshots, not a reason to message native
    // code continuously while the website animates at its own frame rate.
    const next = state(), encoded = JSON.stringify({ ...next, drawCalls: 0 });
    if (!force && encoded === lastSent) return;
    pendingReport = next;
    const bridge = window.flutter_inappwebview;
    if (!bridge || typeof bridge.callHandler !== 'function') return;
    try {
      const result = bridge.callHandler(handlerName, next);
      if (result && typeof result.catch === 'function') result.catch(() => {});
      lastSent = encoded; pendingReport = null;
    } catch (_) { /* A native bridge may become available after document start. */ }
  }
  function cancelWork() {
    clearTimeout(timer); timer = 0;
    cancelAnimationFrame(frame); frame = 0; settling = false;
  }
  function schedule(delay = 80) {
    if (!active() || timer) return;
    timer = setTimeout(() => { timer = 0; check(); }, delay);
  }
  function contextState(context) {
    let entry = contexts.get(context);
    if (!entry) {
      entry = { width: 0, height: 0, uploads: 0, lastUploadAt: 0, draws: 0, framebuffer: null };
      contexts.set(context, entry);
    }
    return entry;
  }
  function earthCanvas(context) {
    const canvas = context && context.canvas;
    if (!canvas || typeof canvas.closest !== 'function') return null;
    const stage = canvas.closest('.home-display .earth-globe-stage');
    if (!stage || canvas.clientWidth <= 0 || canvas.clientHeight <= 0) return null;
    return { canvas, stage };
  }
  function observeDraw(context, args, name) {
    const count = name === 'drawArrays' || name === 'drawArraysInstanced' ? args[2] : name === 'drawRangeElements' ? args[3] : args[1];
    const instances = name === 'drawArraysInstanced' ? args[3] : name === 'drawElementsInstanced' ? args[4] : 1;
    if (!finite(count) || !finite(instances) || context.drawingBufferWidth <= 0 || context.drawingBufferHeight <= 0) return;
    const entry = contextState(context);
    if (entry.framebuffer !== null) return;
    entry.draws += 1;
    if (!active() || route() !== '/display') return;
    const target = earthCanvas(context);
    if (!target) return;
    const changed = !drawn || uploads !== entry.uploads || uploadedWidth !== entry.width || uploadedHeight !== entry.height;
    drawn = true; drawCalls = entry.draws;
    uploads = entry.uploads; uploadedWidth = entry.width; uploadedHeight = entry.height;
    lastUploadAt = entry.lastUploadAt;
    // The site reports its loaded base profile as 2K/4K/8K, then upgrades it
    // progressively. Tiny placeholder uploads must not complete the transition.
    const label = target.stage.getAttribute('data-earth-texture-tier');
    const tier = ({ '2K': 2048, '4K': 4096, '8K': 8192 })[label] || Number(label);
    textureTier = [2048, 4096, 8192].includes(tier) ? tier : null;
    const dpr = Number(target.canvas.getAttribute('data-earth-dpr'));
    if (finite(dpr)) renderDpr = dpr;
    if (changed || !ready) schedule(100);
  }
  function dimensions(source) {
    if (!source || typeof source !== 'object') return null;
    const width = source.videoWidth || source.naturalWidth || source.displayWidth || source.width;
    const height = source.videoHeight || source.naturalHeight || source.displayHeight || source.height;
    return finite(width) && finite(height) ? [width, height] : null;
  }
  function observeUpload(context, args, kind) {
    let size = null;
    if (kind === 'texImage2D') {
      if (args.length >= 9 && args[8] !== null && args[8] !== undefined) size = [args[3], args[4]];
      else if (args.length === 6) size = dimensions(args[5]);
    } else if (kind === 'texSubImage2D') {
      if (args.length >= 9 && args[8] !== null && args[8] !== undefined) size = [args[4], args[5]];
      else if (args.length === 7) size = dimensions(args[6]);
    } else if (kind === 'compressedTexImage2D' && args[6] !== null && args[6] !== undefined) size = [args[3], args[4]];
    else if (kind === 'compressedTexSubImage2D' && args[7] !== null && args[7] !== undefined) size = [args[4], args[5]];
    if (!size || !finite(size[0]) || !finite(size[1])) return;
    const entry = contextState(context);
    entry.uploads += 1; entry.lastUploadAt = clock();
    if (size[0] * size[1] >= entry.width * entry.height) { entry.width = size[0]; entry.height = size[1]; }
    if (earthCanvas(context)) schedule(100);
  }
  const prototypes = new Set();
  for (const constructor of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
    if (constructor && constructor.prototype) prototypes.add(constructor.prototype);
  }
  // Only patch own methods. WebGL2 may inherit a method already patched on WebGL1.
  for (const prototype of prototypes) {
    if (Object.prototype.hasOwnProperty.call(prototype, 'bindFramebuffer')) patch(prototype, 'bindFramebuffer', (context, args) => {
      // READ_FRAMEBUFFER does not redirect visible drawing on WebGL2.
      if (args[0] === 0x8D40 || args[0] === 0x8CA9) contextState(context).framebuffer = args[1];
    });
    for (const name of ['drawArrays', 'drawElements', 'drawArraysInstanced', 'drawElementsInstanced', 'drawRangeElements']) {
      if (Object.prototype.hasOwnProperty.call(prototype, name)) patch(prototype, name, (context, args) => observeDraw(context, args, name));
    }
    for (const name of ['texImage2D', 'texSubImage2D', 'compressedTexImage2D', 'compressedTexSubImage2D']) {
      if (Object.prototype.hasOwnProperty.call(prototype, name)) patch(prototype, name, (context, args) => observeUpload(context, args, name));
    }
  }
  patch(window, 'fetch', (_, args, result) => {
    let url;
    try {
      const input = args[0];
      url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url, location.href);
    } catch (_) { return; }
    if (url.origin !== location.origin || url.pathname !== '/api/display') return;
    const ticket = generation;
    // Observe status only and return the website's original promise unchanged.
    Promise.prototype.then.call(result, (response) => {
      if (destroyed || ticket !== generation || route() !== '/display') return;
      apiObserved = true; apiStatus = response.status;
      if (apiStatus === 401 || apiStatus === 403) ready = false;
      send(); schedule();
    }, () => {}).catch(() => {});
  });
  function imagesReady() {
    for (const image of document.images || []) {
      if (typeof image.getClientRects === 'function' && image.getClientRects().length === 0) continue;
      if (!image.complete) return false;
    }
    return true;
  }
  function contentReady() {
    const path = route();
    if (document.readyState === 'loading' || !fontsReady || document.fonts && document.fonts.status === 'loading' || !imagesReady()) return false;
    if (path === '/login' && !document.querySelector('form input[autocomplete="username"], form input[type="password"]')) return false;
    return path !== '/display' || (apiObserved && apiStatus >= 200 && apiStatus < 300 && drawn && uploads > 0
      && textureTier !== null && uploadedWidth >= textureTier && uploadedHeight >= textureTier / 2
      && clock() - lastUploadAt >= 180);
  }
  function check() {
    if (!active()) return;
    if (navigation !== location.href) resetNavigation();
    if (!ready && contentReady() && !settling) {
      settling = true;
      const ticket = generation;
      frame = requestAnimationFrame(() => {
        frame = requestAnimationFrame(() => {
          frame = 0; settling = false;
          if (!active() || ticket !== generation) return;
          if (!contentReady()) { schedule(); return; }
          ready = true; timedOut = false; send();
        });
      });
    }
    if (!ready && clock() - startedAt >= 30_000) timedOut = true;
    send();
    if (!ready) schedule(timedOut ? 1000 : 100);
  }
  function resetNavigation() {
    cancelWork(); generation += 1; navigation = location.href; startedAt = clock();
    ready = false; timedOut = false; apiObserved = false; apiStatus = null;
    pausedAt = active() ? null : startedAt;
    drawn = false; drawCalls = 0; uploads = 0; uploadedWidth = uploadedHeight = 0;
    textureTier = renderDpr = null; lastUploadAt = 0; fontsReady = !document.fonts;
    const ticket = generation;
    if (document.fonts) Promise.resolve(document.fonts.ready).then(() => {
      if (!destroyed && ticket === generation) { fontsReady = true; schedule(); }
    }, () => { if (!destroyed && ticket === generation) { fontsReady = true; schedule(); } });
    send(true); schedule(0);
  }
  function navigated() { if (navigation !== location.href) resetNavigation(); else schedule(); }
  patch(history, 'pushState', navigated);
  patch(history, 'replaceState', navigated);
  function visibilityChanged() {
    if (!active()) { if (pausedAt === null) pausedAt = clock(); cancelWork(); }
    else {
      if (pausedAt !== null) { startedAt += clock() - pausedAt; pausedAt = null; }
      navigated(); schedule(0);
    }
  }
  const api = {
    setVisible(value) {
      if (destroyed || typeof value !== 'boolean') return;
      const resumed = !visible && value;
      visible = value; visibilityChanged();
      if (resumed && !document.hidden) {
        // Existing site listeners retain ownership of retries and throttling.
        window.dispatchEvent(new Event('online'));
        document.dispatchEvent(new Event('visibilitychange'));
      }
    },
    // Re-evaluate observations; this method never issues a data request or reload.
    refresh() { if (!destroyed) { navigated(); send(true); schedule(0); } },
    getState() { return state(); },
    destroy() {
      if (destroyed) return;
      destroyed = true; generation += 1; cancelWork();
      if (observer) observer.disconnect();
      for (const remove of listeners.reverse()) { try { remove(); } catch (_) {} }
      for (const restore of restorers.reverse()) { try { restore(); } catch (_) {} }
      pendingReport = null;
      if (window.__nakuHomeDisplay === api) delete window.__nakuHomeDisplay;
    },
  };
  window.__nakuHomeDisplay = api;
  listen(window, 'flutterInAppWebViewPlatformReady', () => { if (pendingReport) send(true); });
  listen(window, 'popstate', navigated);
  listen(window, 'hashchange', navigated);
  listen(window, 'pageshow', navigated);
  listen(document, 'visibilitychange', visibilityChanged);
  listen(document, 'DOMContentLoaded', () => schedule(0));
  listen(document, 'load', () => schedule(0), true);
  if (typeof MutationObserver === 'function') {
    observer = new MutationObserver(() => schedule());
    observer.observe(document, { childList: true, subtree: true });
  }
  resetNavigation();
})();
''';
