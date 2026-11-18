// No permanent host permissions: only a genuine action click may grant access.
async function probeTab(tabId) {
  try {
    const result = await chrome.scripting.executeScript({target: {tabId}, func: () => {
      document.body.dataset.contextActions = String(Number(document.body.dataset.contextActions ?? 0) + 1);
      return {url: location.href, draft: document.querySelector('#draft')?.value};
    }});
    return {result: result[0]?.result};
  } catch (error) {return {error: error.message};}
}
chrome.action.onClicked.addListener(async tab => {
  await chrome.storage.local.set({clicked: {tab, ...await probeTab(tab.id)}});
});
