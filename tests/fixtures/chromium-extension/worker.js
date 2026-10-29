chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message !== 'smoke') return;
  chrome.storage.local.get('visits').then(async ({visits = 0}) => {
    await chrome.storage.local.set({visits: visits + 1});
    reply({visits: visits + 1, tabId: sender.tab.id});
  });
  return true;
});
