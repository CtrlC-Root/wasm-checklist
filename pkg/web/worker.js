// https://web.dev/articles/es-modules-in-sw#static_imports_only
import client from "./client.js";

// load and initialize client
// https://developer.mozilla.org/en-US/docs/Web/API/WorkerGlobalScope/location
const loader = new client.ClientLoader(new URL('client.wasm', self.location));
loader.load(); // run async in the background

// XXX: refactor this elsewhere
// https://developer.mozilla.org/en-US/docs/Web/API/Request
const requestToObject = async function (request) {
  console.assert(request instanceof Request);
  const content = await request.text();

  const headers = new Array();
  for (const entry of request.headers.entries()) {
    headers.push({name: entry[0], value: entry[1]});
  }

  return {
    url: request.url,
    method: request.method,
    headers: headers,
    content: content
  };
};

// XXX: refactor this elsewhere
// https://developer.mozilla.org/en-US/docs/Web/API/Response
const responseFromObject = async function (data) {
  return new Response(data.content, {
    status: data.status,
    headers: Object.fromEntries(data.headers.map((header) => {
      return [header.name, header.value];
    })),
  });
};

// XXX: unique incrementing ID for requests
var requestId = 0;

// XXX: process application request to response
const application = async function (request) {
  const loadedClient = await loader.client;
  const requestObject = await requestToObject(request);

  // XXX
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const byteArraySpec = new client.TypedArraySpecification('uint8'); // kinda verbose

  // XXX: this should be encapsulated in a movable JSON object type?
  requestId += 1; // increment the request id
  const input = {
    requestId: requestId,
    httpRequest: requestObject,
  };

  console.debug("APP INVOKE INPUT:", input);
  var inputData = encoder.encode(JSON.stringify(input));
  var inputBuffer = new client.ClientArrayBuffer(byteArraySpec, inputData.buffer.transfer());
  loadedClient.moveArrayBufferIn(inputBuffer); // allocates buffer memory inside client

  // invoke the client
  const exports = loadedClient.instance.exports;
  var outputSlice = new client.PackedSlice(exports.memory, exports.invoke(inputBuffer.slice.value));
  var outputBuffer = new client.ClientArrayBuffer(byteArraySpec, outputSlice); // uses existing memory inside client

  // XXX: this should be encapsulated in a movable JSON object type?
  var output = JSON.parse(decoder.decode(outputBuffer.array));
  console.debug("APP INVOKE OUTPUT:", output);

  // free request and response memory in the client
  loadedClient.moveArrayBufferOut(inputBuffer);  // deallocates buffer memory inside client
  loadedClient.moveArrayBufferOut(outputBuffer); // deallocates buffer memory inside client

  // handle client errors by throwing
  if (Object.hasOwn(output, "error")) {
    throw new Error(`client invoke error: ${output.error.id}`);
  }

  // XXX
  console.assert(Object.hasOwn(output, "httpResponse"));
  return await responseFromObject(output.httpResponse);
};

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
      event.respondWith(application(event.request));
      return;
    }
  }

  // fall through and let the browser handle the request
  event.respondWith(fetch(event.request));
});
