// Save to Aigle — MV3 service worker.
//
// Everything is posted to the Aigle app's local server on 127.0.0.1. Nothing
// leaves the machine, and the request must carry the token shown in
// Aigle → Settings → Extensions.

const DEFAULT_PORT = 41417;

const MENU_ITEMS = [
  { id: "aigle-image", title: "Save Image to Aigle", contexts: ["image"] },
  { id: "aigle-video", title: "Save Video to Aigle", contexts: ["video"] },
  { id: "aigle-link", title: "Save Link to Aigle", contexts: ["link"] },
  { id: "aigle-page", title: "Save Page to Aigle", contexts: ["page"] },
];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    for (const item of MENU_ITEMS) chrome.contextMenus.create(item);
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const payload = describe(info, tab);
  if (payload) save(payload);
});

chrome.action.onClicked.addListener((tab) => {
  if (!tab?.url) return;
  save({ url: tab.url, pageUrl: tab.url, title: tab.title || "", type: "page" });
});

function describe(info, tab) {
  const pageUrl = info.pageUrl || tab?.url || "";
  const title = tab?.title || "";
  switch (info.menuItemId) {
    case "aigle-image":
      return { url: info.srcUrl, pageUrl, title, type: "image" };
    case "aigle-video":
      return { url: info.srcUrl, pageUrl, title, type: "video" };
    case "aigle-link":
      return { url: info.linkUrl, pageUrl, title, type: "link" };
    case "aigle-page":
      return { url: pageUrl, pageUrl, title, type: "page" };
    default:
      return null;
  }
}

async function settings() {
  const stored = await chrome.storage.sync.get({ port: DEFAULT_PORT, token: "" });
  return stored;
}

async function save(payload) {
  if (!payload.url) return;
  const { port, token } = await settings();
  if (!token) {
    notify("Aigle needs a token", "Open the extension options and paste the token from Aigle → Settings → Extensions.");
    return;
  }
  try {
    const response = await fetch(`http://127.0.0.1:${port}/save`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Aigle-Token": token },
      body: JSON.stringify(payload),
    });
    if (response.ok) {
      notify("Saved to Aigle", payload.title || payload.url);
    } else if (response.status === 401) {
      notify("Aigle rejected the token", "Copy a fresh token from Aigle → Settings → Extensions.");
    } else {
      notify("Aigle couldn’t save that", `The app replied ${response.status}.`);
    }
  } catch (error) {
    notify("Aigle isn’t listening", "Open Aigle and turn on the browser extension server in Settings.");
  }
}

function notify(title, message) {
  chrome.notifications.create({
    type: "basic",
    iconUrl: "icon128.png",
    title,
    message: message || "",
  });
}
