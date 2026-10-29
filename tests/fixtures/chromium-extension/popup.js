document.querySelector('#run').onclick = async () => {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  await chrome.scripting.executeScript({target: {tabId: tab.id}, func: () => {document.body.dataset.extensionAction = 'passed';}});
  document.querySelector('#status').textContent = 'activeTab + scripting passed';
};
