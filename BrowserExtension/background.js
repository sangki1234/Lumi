// background.js — Lumi Browser Workspace extension
// Clicking the toolbar button opens (or focuses) the Lumi panel page.

const PANEL_URL = 'http://localhost:47287/panel';

chrome.action.onClicked.addListener(async () => {
  // Check if the panel tab is already open; focus it if so.
  const tabs = await chrome.tabs.query({ url: PANEL_URL });
  if (tabs.length > 0) {
    chrome.tabs.update(tabs[0].id, { active: true });
    chrome.windows.update(tabs[0].windowId, { focused: true });
  } else {
    chrome.tabs.create({ url: PANEL_URL });
  }
});
