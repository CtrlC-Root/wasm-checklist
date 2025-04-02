// https://web.dev/articles/es-modules-in-sw#static_imports_only
import client from "./client.js";

// load and initialize client
// https://developer.mozilla.org/en-US/docs/Web/API/WorkerGlobalScope/location
const loader = new client.ClientLoader(new URL('client.wasm', self.location));
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

// XXX: refactor this into the client class
const invoke = function (loadedClient, input) {
  console.debug("invoke input:", input);

  // XXX: cache and reuse these across calls to this method
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const byteArraySpec = new client.TypedArraySpecification('uint8'); // kinda verbose

  // XXX: this should be encapsulated in a movable JSON object type?
  var inputData = encoder.encode(JSON.stringify(input));
  var inputBuffer = new client.ClientArrayBuffer(byteArraySpec, inputData.buffer.transfer());
  loadedClient.moveArrayBufferIn(inputBuffer); // allocates buffer memory inside client

  // invoke the client
  const exports = loadedClient.instance.exports;
  var outputSlice = new client.PackedSlice(exports.memory, exports.invoke(inputBuffer.slice.value));

  // XXX: this should be encapsulated in a movable JSON object type?
  var outputBuffer = new client.ClientArrayBuffer(byteArraySpec, outputSlice); // uses existing memory inside client
  var output = JSON.parse(decoder.decode(outputBuffer.array));

  // free request and response memory in the client
  loadedClient.moveArrayBufferOut(inputBuffer);  // deallocates buffer memory inside client
  loadedClient.moveArrayBufferOut(outputBuffer); // deallocates buffer memory inside client

  console.debug("invoke output:", output);

  // handle client errors by throwing
  if (Object.hasOwn(output, "error")) {
    throw new Error(`invoke error: ${output.error.id}`);
  }

  return output;
}

// XXX: refactor this into the client class
const getTask = function (loadedClient, requestId, taskId) {
  console.debug(`getTask input: ${requestId}, ${taskId}`);

  // XXX: cache and reuse these across calls to this method
  const decoder = new TextDecoder();
  const byteArraySpec = new client.TypedArraySpecification('uint8'); // kinda verbose

  // invoke the client
  const exports = loadedClient.instance.exports;
  var outputSlice = new client.PackedSlice(exports.memory, exports.getTask(requestId, taskId));

  // XXX: this should be encapsulated in a movable JSON object type?
  var outputBuffer = new client.ClientArrayBuffer(byteArraySpec, outputSlice); // uses existing memory inside client
  var output = JSON.parse(decoder.decode(outputBuffer.array));

  // free request and response memory in the client
  loadedClient.moveArrayBufferOut(outputBuffer); // deallocates buffer memory inside client

  console.debug(`getTask output:`, output);

  // handle client errors by throwing
  if (Object.hasOwn(output, "error")) {
    throw new Error(`getTask error: ${output.error.id}`);
  }

  return output;
}

// XXX: refactor this into the client class
const completeTask = function (loadedClient, requestId, taskId, data) {
  console.debug(`completeTask input: ${requestId}, ${taskId}:`, data);

  // XXX: cache and reuse these across calls to this method
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const byteArraySpec = new client.TypedArraySpecification('uint8'); // kinda verbose

  // XXX: this should be encapsulated in a movable JSON object type?
  var inputData = encoder.encode(JSON.stringify(data));
  var inputBuffer = new client.ClientArrayBuffer(byteArraySpec, inputData.buffer.transfer());
  loadedClient.moveArrayBufferIn(inputBuffer); // allocates buffer memory inside client

  // invoke the client
  const exports = loadedClient.instance.exports;
  var outputSlice = new client.PackedSlice(exports.memory, exports.completeTask(requestId, taskId, inputBuffer.slice.value));

  // XXX: this should be encapsulated in a movable JSON object type?
  var outputBuffer = new client.ClientArrayBuffer(byteArraySpec, outputSlice); // uses existing memory inside client
  var output = JSON.parse(decoder.decode(outputBuffer.array));

  // free request and response memory in the client
  loadedClient.moveArrayBufferOut(inputBuffer);  // deallocates buffer memory inside client
  loadedClient.moveArrayBufferOut(outputBuffer); // deallocates buffer memory inside client

  console.debug("completeTask output:", output);

  // handle client errors by throwing
  if (Object.hasOwn(output, "error")) {
    throw new Error(`completeTask error: ${output.error.id}`);
  }

  return output;
}

// XXX: unique incrementing ID for requests
// TODO: manage request IDs to ensure we wrap around to fit within a u32 type
// and do not reuse any values that are in use by in-progress requests
var lastRequestId = 0;

// process an application request into a response
const application = async function (request) {
  const loadedClient = await loader.client;
  const requestObject = await requestToObject(request);

  // prepare input data from application request
  const requestId = ++lastRequestId; // use unique request IDs
  const input = {
    requestId: requestId,
    httpRequest: requestObject,
  };

  // process the request into a response
  var remainingInvokeAttempts = 3; // XXX: artificial limit to prevent infinite looping
  var output = invoke(loadedClient, input);
  while (Object.hasOwn(output, "pendingTasks") && remainingInvokeAttempts > 0) {
    for (const taskId of output.pendingTasks.taskIds) {
      console.debug(`proccessing request ${requestId} task ${taskId}`);

      const taskData = getTask(loadedClient, requestId, taskId);
      console.assert(Object.hasOwn(taskData.data, "http"));

      const requestData = taskData.data.http.request;
      const request = await requestFromObject(requestData);

      try {
        const response = await fetch(request);
        const responseData = await responseToObject(response);
        completeTask(loadedClient, requestId, taskId, { response: responseData });
      } catch (error) {
        // TODO: actually use error to determine this
        completeTask(loadedClient, requestId, taskId, { error: "connect_failed" });
      }
    }

    // attempt to process the request again
    remainingInvokeAttempts -= 1; // XXX    
    output = invoke(loadedClient, input);
  }

  // XXX
  if (Object.hasOwn(output, "pendingTasks")) {
    throw new Error("application ran out of attempts to process pending tasks");
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
