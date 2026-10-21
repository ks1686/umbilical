// SPDX-License-Identifier: GPL-3.0-or-later
// Sends a URL and an optional file name to the umbilical app. Nothing else.
// Safari hides extension context menus unless the extension already has
// website access or declares activeTab. See WebExtensionContext::addItemsToContextMenu
// in WebKit. Click interception is opt-in and uses optional host access.

const api = globalThis.browser ?? globalThis.chrome;
const downloadMenuID = "download-with-umbilical";
const videoMenuID = "download-video-with-umbilical";
const appID = "me.peapod.umbilical";
const captureKey = "captureDownloads";

function menuAPI() {
  if (!api) return null;
  return api.contextMenus ?? api.menus ?? null;
}

function downloadMenuSpec() {
  return {
    id: downloadMenuID,
    title: "Download with umbilical",
    contexts: ["link"],
  };
}

function videoMenuSpec() {
  return {
    id: videoMenuID,
    title: "Download video with umbilical",
    contexts: ["page", "link"],
  };
}

function createMenus() {
  const menu = menuAPI();
  if (!menu || typeof menu.create !== "function") return;
  try {
    menu.create(downloadMenuSpec());
  } catch {
    // The item is already registered for this background page.
  }
  try {
    menu.create(videoMenuSpec());
  } catch {
    // The item is already registered for this background page.
  }
}

function replaceMenus() {
  const menu = menuAPI();
  if (!menu || typeof menu.remove !== "function") {
    createMenus();
    return;
  }
  const afterRemove = () => createMenus();
  const removeOne = (id) => {
    try {
      const pending = menu.remove(id);
      if (pending && typeof pending.then === "function") {
        return pending.catch(() => {});
      }
    } catch {
      // The item was not registered.
    }
    return Promise.resolve();
  };
  Promise.all([removeOne(downloadMenuID), removeOne(videoMenuID)]).then(afterRemove, afterRemove);
}

function isPlainFilename(name) {
  if (!name || name === "." || name === "..") return false;
  if (name.length > 255) return false;
  if (name.charAt(0) === "-") return false;
  return !/[\\/\u0000\r\n]/.test(name);
}

function suggestedFilename(urlString) {
  let parsed;
  try {
    parsed = new URL(urlString);
  } catch {
    return "";
  }
  if (parsed.protocol === "magnet:") return "";
  const parts = parsed.pathname.split("/").filter((part) => part.length > 0);
  if (parts.length === 0) return "";
  let name = parts[parts.length - 1];
  try {
    name = decodeURIComponent(name);
  } catch {
    return "";
  }
  return isPlainFilename(name) ? name : "";
}

function once(resolve) {
  let done = false;
  return (value) => {
    if (done) return;
    done = true;
    resolve(value);
  };
}

function sendHandoff(url, filename, video) {
  return new Promise((resolve) => {
    const finish = once((accepted) => resolve(accepted === true));
    if (!api || !api.runtime || typeof api.runtime.sendNativeMessage !== "function") {
      finish(false);
      return;
    }
    if (typeof url !== "string" || url.length === 0 || url.length > 4096) {
      finish(false);
      return;
    }
    if (url.charAt(0) === "-") {
      finish(false);
      return;
    }
    const message = { url };
    if (typeof filename === "string" && isPlainFilename(filename)) {
      message.filename = filename;
    }
    if (video === true) {
      message.video = true;
    }
    try {
      const pending = api.runtime.sendNativeMessage(appID, message, (reply) => {
        finish(reply && reply.accepted === true);
      });
      if (pending && typeof pending.then === "function") {
        pending.then((reply) => finish(reply && reply.accepted === true)).catch(() => finish(false));
      }
    } catch {
      finish(false);
    }
  });
}

function onMenuClick(info) {
  if (!info) return;
  if (info.menuItemId === downloadMenuID) {
    if (typeof info.linkUrl !== "string") return;
    sendHandoff(info.linkUrl, suggestedFilename(info.linkUrl), false);
    return;
  }
  if (info.menuItemId !== videoMenuID) return;
  let url = "";
  if (typeof info.linkUrl === "string" && info.linkUrl.length > 0) {
    url = info.linkUrl;
  } else if (typeof info.pageUrl === "string") {
    url = info.pageUrl;
  }
  if (!url) return;
  sendHandoff(url, suggestedFilename(url), true);
}

async function captureEnabled() {
  if (!api || !api.storage || !api.storage.local) return false;
  try {
    const stored = await api.storage.local.get(captureKey);
    return stored && stored[captureKey] === true;
  } catch {
    return false;
  }
}

function onMessage(message, _sender, sendResponse) {
  if (!message || typeof message !== "object") return;
  if (message.type === "umbilical-capture-state") {
    captureEnabled().then((enabled) => sendResponse({ enabled: enabled === true }));
    return true;
  }
  if (message.type !== "umbilical-intercept") return;
  const url = typeof message.url === "string" ? message.url : "";
  const filename = typeof message.filename === "string" ? message.filename : "";
  sendHandoff(url, filename, false).then((accepted) => {
    sendResponse({ accepted: accepted === true });
  });
  return true;
}

createMenus();
const menu = menuAPI();
if (menu && menu.onClicked && typeof menu.onClicked.addListener === "function") {
  menu.onClicked.addListener(onMenuClick);
}
if (api && api.runtime) {
  if (api.runtime.onInstalled && typeof api.runtime.onInstalled.addListener === "function") {
    api.runtime.onInstalled.addListener(replaceMenus);
  }
  if (api.runtime.onStartup && typeof api.runtime.onStartup.addListener === "function") {
    api.runtime.onStartup.addListener(replaceMenus);
  }
  if (api.runtime.onMessage && typeof api.runtime.onMessage.addListener === "function") {
    api.runtime.onMessage.addListener(onMessage);
  }
}
