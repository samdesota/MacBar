const HOST_NAME = "bar.favicon.bridge";

const tabState = new Map();
const lastSentPayload = new Map(); // Track last sent payload per tab to avoid duplicates
let port = null;

function connectNative() {
  if (port) return;
  try {
    port = browser.runtime.connectNative(HOST_NAME);
    
    // Listen for messages FROM the native host
    port.onMessage.addListener((message) => {
      if (message.type === "clearCache") {
        console.log("Received clearCache command from native host");
        lastSentPayload.clear();
        console.log("Cleared dedup cache");
      }
    });
    
    port.onDisconnect.addListener(() => {
      console.warn("Native messaging disconnected.");
      // Clear cache on disconnect (Firefox/extension restart)
      lastSentPayload.clear();
      console.log("Cleared dedup cache on disconnect");
      port = null;
    });
  } catch (err) {
    console.error("Failed to connect native messaging host:", err);
  }
}

function getActiveTabForWindow(windowId) {
  return browser.tabs.query({ windowId, active: true }).then((tabs) => tabs[0]);
}

function emitUpdate(windowId, tab) {
  if (!tab) return;
  const payload = {
    type: "tabUpdate",
    windowId,
    url: tab.url || "",
    title: tab.title || "",
    favIconUrl: tab.favIconUrl || ""
  };

  // Deduplication: check if we already sent this exact payload for this tab
  const payloadKey = `${tab.id}`;
  const lastPayload = lastSentPayload.get(payloadKey);
  const payloadString = JSON.stringify(payload);
  
  if (lastPayload === payloadString) {
    // Skip sending duplicate
    return;
  }
  
  // Store this payload as the last sent
  lastSentPayload.set(payloadKey, payloadString);

  connectNative();
  if (port) {
    port.postMessage(payload);
  }
}

function syncTabState(tabId, tab) {
  const prev = tabState.get(tabId) || {};
  const next = {
    url: tab.url || prev.url || "",
    title: tab.title || prev.title || "",
    favIconUrl: tab.favIconUrl || prev.favIconUrl || "",
    windowId: tab.windowId
  };

  tabState.set(tabId, next);

  const urlChanged = prev.url !== next.url;
  const titleChanged = prev.title !== next.title;
  const iconChanged = prev.favIconUrl !== next.favIconUrl;

  // Emit update if URL, title, or favicon changed
  if (urlChanged || titleChanged || iconChanged) {
    emitUpdate(tab.windowId, tab);
    
    // Also emit updates for all other tabs in the same window (with dedup)
    emitAllTabsInWindow(tab.windowId);
  }
}

function emitAllTabsInWindow(windowId) {
  browser.tabs.query({ windowId }).then((tabs) => {
    tabs.forEach((tab) => {
      // Only emit if we have valid data for this tab
      if (tab.url && tab.favIconUrl) {
        emitUpdate(windowId, tab);
      }
    });
  });
}

browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!tab) return;
  
  // Emit updates for URL, title, favicon changes, or when page completes loading
  const hasRelevantChange = changeInfo.url || changeInfo.title || changeInfo.favIconUrl || changeInfo.status === "complete";
  
  if (hasRelevantChange) {
    syncTabState(tabId, tab);
  }
});

browser.tabs.onActivated.addListener(({ tabId, windowId }) => {
  browser.tabs.get(tabId).then((tab) => {
    syncTabState(tabId, tab);
    emitUpdate(windowId, tab);
  });
});

browser.windows.onFocusChanged.addListener((windowId) => {
  if (windowId === browser.windows.WINDOW_ID_NONE) return;
  getActiveTabForWindow(windowId).then((tab) => emitUpdate(windowId, tab));
});

browser.runtime.onInstalled.addListener(() => {
  browser.windows.getAll({ populate: true }).then((windows) => {
    windows.forEach((win) => {
      const activeTab = win.tabs && win.tabs.find((t) => t.active);
      if (activeTab) {
        syncTabState(activeTab.id, activeTab);
        emitUpdate(win.id, activeTab);
      }
    });
  });
});
