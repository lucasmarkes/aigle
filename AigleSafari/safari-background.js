// Aigle — Safari Web Extension background service worker.
// Adds "Save to Aigle" context menu entries and forwards the payload to the
// native handler, which deep-links into the app.

const MENU = [
  { id: "aigle-save-image", title: "Save Image to Aigle", contexts: ["image"] },
  { id: "aigle-save-video", title: "Save Video to Aigle", contexts: ["video"] },
  { id: "aigle-save-link", title: "Save Link to Aigle", contexts: ["link"] },
  { id: "aigle-save-page", title: "Save Page to Aigle", contexts: ["page"] },
];

browser.runtime.onInstalled.addListener(() => {
  for (const item of MENU) browser.contextMenus.create(item);
});

browser.contextMenus.onClicked.addListener((info, tab) => {
  let url = null;
  let type = "page";
  if (info.menuItemId === "aigle-save-image") { url = info.srcUrl; type = "image"; }
  else if (info.menuItemId === "aigle-save-video") { url = info.srcUrl; type = "video"; }
  else if (info.menuItemId === "aigle-save-link") { url = info.linkUrl; type = "link"; }
  else { url = info.pageUrl || (tab && tab.url); type = "page"; }
  if (!url) return;
  browser.runtime.sendNativeMessage("cool.aigle.Aigle.Safari", {
    action: "save",
    url,
    pageUrl: info.pageUrl || (tab && tab.url) || "",
    title: (tab && tab.title) || "",
    type,
  });
});

browser.action.onClicked.addListener((tab) => {
  if (!tab || !tab.url) return;
  browser.runtime.sendNativeMessage("cool.aigle.Aigle.Safari", {
    action: "save",
    url: tab.url,
    pageUrl: tab.url,
    title: tab.title || "",
    type: "page",
  });
});
