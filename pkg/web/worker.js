// https://web.dev/articles/es-modules-in-sw#static_imports_only
import client from "./client.js";

// load and initialize client
// https://developer.mozilla.org/en-US/docs/Web/API/WorkerGlobalScope/location
var loader = new client.ClientLoader(new URL('client.wasm', self.location));
loader.load(); // run async in the background

// service worker lifecycle events
self.addEventListener('install', async (event) => {
  const client = await loader.client;

  // TODO: retrieve and cache client assets
  // XXX: worker lifecycle
});

self.addEventListener('activate', async (event) => {
  const client = await loader.client;

  // XXX: worker lifecycle
});

self.addEventListener('fetch', async (event) => {
  const client = await loader.client;
  const requestUrl = new URL(event.request.url);

  // XXX: only requests for our origin
  if (requestUrl.origin === self.location.origin) {
    // XXX: client static assets
    if (requestUrl.pathname.startsWith('/static')) {
      // TODO: cache then fall through
    }

    // XXX: client requests
    if (requestUrl.pathname.startsWith('/app')) {
      // TODO
    }
  }

  // fall through and let the browser handle the request
  event.respondWith(fetch(event.request));
});
