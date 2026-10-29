chrome.runtime.sendMessage('smoke', result => {
  document.body.dataset.extensionVisits = String(result.visits);
  document.body.dataset.extensionTab = String(result.tabId);
  document.querySelector('h1').textContent = 'MV3 content + service worker + storage: ' + result.visits;
});
