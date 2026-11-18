const instance = crypto.randomUUID();
let clicks = 0;
document.querySelector('#item').addEventListener('click', async () => {
  document.querySelector('#detail').hidden = false;
  await chrome.storage.local.set({interaction: {
    instance, clicks: ++clicks, draft: document.querySelector('#draft').value,
    elapsed: performance.now(), detail: document.querySelector('#detail').textContent
  }});
});
(async () => {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  let execution;
  try {
    const results = await chrome.scripting.executeScript({target: {tabId: tab.id}, func: () => {
      document.body.dataset.contextActions = String(Number(document.body.dataset.contextActions ?? 0) + 1);
      return {url: location.href, draft: document.querySelector('#draft')?.value};
    }});
    execution = results[0]?.result;
  } catch (error) {execution = {error: error.message};}
  const result = {tab, execution, contexts: await chrome.runtime.getContexts({contextTypes: ['POPUP']})};
  document.querySelector('#result').textContent = JSON.stringify(result, null, 2);
  await chrome.storage.local.set({popup: result});
})();
