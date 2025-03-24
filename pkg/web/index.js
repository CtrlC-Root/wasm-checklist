// DEBUG
import * as client from "./client.js";
window.PackedSlice = client.PackedSlice;
window.Client = client.Client;
window.ClientLoader = client.ClientLoader;

// since the script is included in the <head> element we need to wait for the
// document content to load before we run or we won't be able to interact with
// any elements
function start(fn) {
    // see if DOM is already available
    if (document.readyState === "complete" || document.readyState === "interactive") {
        // call on next available tick
        setTimeout(fn, 1);
    } else {
        document.addEventListener("DOMContentLoaded", fn);
    }
} 

// entry point
start(async () => {
    // TODO: service worker
    // TODO: initial application load

    // https://stackoverflow.com/a/73659697
    // https://htmx.org/api/#process
    //htmx.process(document.body);
});
