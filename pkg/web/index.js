// DEBUG
import client from "./client.js";
Object.assign(window, client);

// since the script is included in the <head> element we need to wait for the
// document content to load before we run or we won't be able to interact with
// any elements
function start(fn) {
    // see if DOM is already available
    if (document.readyState === 'complete' || document.readyState === 'interactive') {
        // call on next available tick
        setTimeout(fn, 1);
    } else {
        document.addEventListener('DOMContentLoaded', fn);
    }
} 

// entry point
start(async () => {
    // install or update the service worker
    if (!('serviceWorker' in navigator)) {
        console.error("service worker functionality is not available!");
        return;
    }

    try {
        // https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerContainer/register
        const workerUrl = new URL('worker.js', window.location);
        const registration = await navigator.serviceWorker.register(workerUrl.toString(), {
            // https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerContainer/register#scope
            scope: '/',
            // https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerContainer/register#type
            type: 'module',
        });

        if (registration.installing) {
            console.log("Service worker installing");
        } else if (registration.waiting) {
            console.log("Service worker installed");
        } else if (registration.active) {
            const serviceWorker = registration.active;
            console.log(`Service worker active: ${serviceWorker.state}`);
        }
    } catch (error) {
        console.error(`Service worker registration failed: ${error}`);
        return;
    }

    // XXX: detect hard refresh by trying to communicate with the service
    // worker and if it fails use location.reload() to reload the page

    // TODO: initial application load

    // https://stackoverflow.com/a/73659697
    // https://htmx.org/api/#process
    //htmx.process(document.body);

    // DEBUG
    var loader = new client.ClientLoader(new URL("client.wasm", window.location));
    var testClient = await loader.load();
    window.testClient = testClient;

    var input = {traceId: 123, httpRequest: {
        url: (new URL("/version", window.location)).toString(),
        method: "GET",
        headers: [],
        content: "",
    }};

    window.testInput = input;

    const byteArraySpec = new client.TypedArraySpecification('uint8'); // kinda verbose

    var inputData = (new TextEncoder()).encode(JSON.stringify(input));
    var inputBuffer = new client.ClientArrayBuffer(byteArraySpec, inputData.buffer.transfer());
    testClient.moveArrayBufferIn(inputBuffer); // allocates buffer memory inside client

    const exports = testClient.instance.exports;
    var outputSlice = new client.PackedSlice(exports.memory, exports.invoke(inputBuffer.slice.value));
    var outputBuffer = new client.ClientArrayBuffer(byteArraySpec, outputSlice); // uses existing memory inside client

    var output = JSON.parse((new TextDecoder()).decode(outputBuffer.array));
    window.testOutput = output;

    testClient.moveArrayBufferOut(inputBuffer);  // deallocates buffer memory inside client
    testClient.moveArrayBufferOut(outputBuffer); // deallocates buffer memory inside client

    console.log("input:", input);
    console.log("output:", output);
});
