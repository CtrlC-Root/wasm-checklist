// DEBUG
import app from "./application.js";
Object.assign(window, app);

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
    const versionUrl = new URL('/app/version', window.location);
    const versionResponse = await fetch(versionUrl.toString());
    if (!versionResponse.ok) {
        console.error("forcing page reload to use service worker");
        location.reload();
        return;
    }

    const appVersion = await versionResponse.text();
    console.log(`application version: ${appVersion}`);

    // manually load the initial application view
    const appResponse = await fetch("/app");
    if (!appResponse.ok) {
        console.error("failed to load the application:", appResponse);
        return;
    }

    // parse the application HTML and add it to the document in a way that will
    // execute <script> tags in order to dynamically load required resources
    // https://developer.mozilla.org/en-US/docs/Web/API/Range/createContextualFragment
    const appHtml = await appResponse.text();
    const documentRange = document.createRange();
    document.body.appendChild(documentRange.createContextualFragment(appHtml));
});
