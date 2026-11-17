importScripts('probe.js');
// Start without accounts, native hosts, or external URLs. probeOrigin runs here
// when the diagnostic harness asks for a GET or POST to its local echo server.
chrome.runtime.onInstalled.addListener(() => {});
