document.querySelector('#run').onclick = async () => {
  const status = document.querySelector('#status');
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!tab) throw new Error('No active Chrome tab (embedded tabs are not returned by tabs.query)');
    await chrome.scripting.executeScript({target: {tabId: tab.id}, func: () => {document.body.dataset.extensionAction = 'passed';}});
    status.textContent = `scripting passed on queried tab ${tab.id} (host permission or activeTab)`;
  } catch (error) {status.textContent = error.message;}
};
