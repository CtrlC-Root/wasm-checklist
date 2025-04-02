// https://web.dev/articles/es-modules-in-sw#static_imports_only
import app from "./application.js";

// load and initialize client
// https://developer.mozilla.org/en-US/docs/Web/API/WorkerGlobalScope/location
const loader = new app.Loader(new URL('application.wasm', self.location));
loader.load(); // start running async in the background

// XXX: refactor this elsewhere (maybe into a wrapper type)
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

// XXX: refactor this elsewhere (maybe into a wrapper type)
// https://developer.mozilla.org/en-US/docs/Web/API/Request
const requestFromObject = async function (data) {
  // XXX: might need to specify Request mode in constructor
  // https://developer.mozilla.org/en-US/docs/Web/API/Request/mode

  const options = {
    method: data.method,
    headers: Object.fromEntries(data.headers.map((header) => {
      return [header.name, header.value];
    })),
  };

  if (data.method == 'GET' || data.method == 'HEAD') {
    console.assert(data.content == "");
  } else {
    options.body = data.content;
  }

  return new Request(data.url, options);
}

// XXX: refactor this elsewhere
// https://developer.mozilla.org/en-US/docs/Web/API/Response
const responseToObject = async function (response) {
  console.assert(response instanceof Response);
  const content = await response.text();

  const headers = new Array();
  for (const entry of response.headers.entries()) {
    headers.push({name: entry[0], value: entry[1]});
  }

  return {
    status: response.status,
    headers: headers,
    content: content,
  };
}

// XXX: refactor this elsewhere (maybe into a wrapper type)
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
// TODO: manage request IDs to ensure we wrap around to fit within a u32 type
// and do not reuse any values that are in use by in-progress requests
var lastRequestId = 0;

// process an application request into a response
const applicationRequest = async function (request) {
  const application = await loader.application;
  const requestObject = await requestToObject(request);

  // prepare input data from application request
  const requestId = ++lastRequestId; // use unique request IDs
  const input = {
    requestId: requestId,
    httpRequest: requestObject,
  };

  // TODO: we should process pending tasks into promises then await on all of
  // them to complete in parallel instead of processing pending tasks one at a
  // time in series which could take much longer

  // TODO: should requests guarantee they complete within a fixed number of
  // attempts and if not then what would be a reasonable upper limit? can the
  // view itself inform the caller how many attempts will be required?

  // process the request into a response
  var remainingInvokeAttempts = 3; // XXX: artificial limit to prevent infinite looping
  var output = application.invoke(input);
  while (Object.hasOwn(output, "pendingTasks")) {
    if (remainingInvokeAttempts == 0) {
      throw new Error("application ran out of attempts to process pending tasks");
    }

    for (const taskId of output.pendingTasks.taskIds) {
      console.debug(`proccessing request ${requestId} task ${taskId}`);

      const taskData = application.getTask(requestId, taskId);
      console.assert(Object.hasOwn(taskData.data, "http"));

      const requestData = taskData.data.http.request;
      const request = await requestFromObject(requestData);

      try {
        const response = await fetch(request);
        const responseData = await responseToObject(response);
        application.completeTask(requestId, taskId, { response: responseData });
      } catch (error) {
        // TODO: actually use caught error to determine this
        const taskError = "connect_failed";
        application.completeTask(requestId, taskId, { error: taskError });
      }
    }

    // attempt to process the request again
    remainingInvokeAttempts -= 1;
    output = application.invoke(input);
  }

  // convert output data into application response
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
  const requestUrl = new URL(event.request.url);

  // XXX: only requests for our origin
  if (requestUrl.origin === self.location.origin) {
    // XXX: static assets
    if (requestUrl.pathname.startsWith('/static/')) {
      // TODO: cache or fetch and cache requests
      event.respondWith(new Response(500, { body: "TODO: implement this" }));
      return;
    }

    // application
    if (requestUrl.pathname == '/app' || requestUrl.pathname.startsWith('/app/')) {
      event.respondWith(applicationRequest(event.request));
      return;
    }
  }

  // fall through and let the browser handle the request
  event.respondWith(fetch(event.request));
});
