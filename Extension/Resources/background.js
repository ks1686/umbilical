// SPDX-License-Identifier: GPL-3.0-or-later
// Sends a URL and an optional file name to the umbilical app. Nothing else.

const api = globalThis.browser ?? globalThis.chrome;
const menuID = "download-with-umbilical";
const captureKey = "captureDownloads";
const appID = "me.peapod.umbilical";

let captureAttached = false;

function menuAPI() {
  if (!api) return null;
  return api.contextMenus ?? api.menus ?? null;
}

function installMenu() {
  const menu = menuAPI();
  if (!menu || typeof menu.create !== "function") return;
  const spec = {
    id: menuID,
    title: "Download with umbilical",
    contexts: ["link"],
  };
  let created = false;
  const create = () => {
    if (created) return;
    created = true;
    try {
      menu.create(spec);
    } catch {
      // The item is already registered for this page.
    }
  };
  if (typeof menu.removeAll !== "function") {
    create();
    return;
  }
  try {
    const pending = menu.removeAll(create);
    if (pending && typeof pending.then === "function") {
      pending.then(create).catch(create);
    }
  } catch {
    create();
  }
}

function isPlainFilename(name) {
  if (!name || name === "." || name === "..") return false;
  if (name.length > 255) return false;
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

function basename(path) {
  if (typeof path !== "string" || path.length === 0) return "";
  const parts = path.split(/[/\\]/).filter((part) => part.length > 0);
  if (parts.length === 0) return "";
  const name = parts[parts.length - 1];
  return isPlainFilename(name) ? name : "";
}

function acceptedDownloadURL(urlString) {
  try {
    const protocol = new URL(urlString).protocol;
    return protocol === "http:" || protocol === "https:" || protocol === "magnet:";
  } catch {
    return false;
  }
}

function sendHandoff(url, filename, done) {
  if (!api || !api.runtime || typeof api.runtime.sendNativeMessage !== "function") {
    if (typeof done === "function") done(false);
    return;
  }
  if (typeof url !== "string" || url.length === 0 || url.length > 4096) {
    if (typeof done === "function") done(false);
    return;
  }
  const message = { url };
  if (typeof filename === "string" && isPlainFilename(filename)) {
    message.filename = filename;
  }
  api.runtime.sendNativeMessage(appID, message, (response) => {
    const failed = Boolean(api.runtime.lastError) || !response || response.accepted !== true;
    if (typeof done === "function") done(!failed);
  });
}

function onMenuClick(info) {
  if (!info || info.menuItemId !== menuID) return;
  if (typeof info.linkUrl !== "string") return;
  sendHandoff(info.linkUrl, suggestedFilename(info.linkUrl));
}

function onDownloadCreated(item) {
  if (!item || typeof item.url !== "string") return;
  if (!acceptedDownloadURL(item.url)) return;
  const filename = basename(item.filename);
  sendHandoff(item.url, filename, (delivered) => {
    if (!delivered || typeof item.id !== "number") return;
    if (!api.downloads || typeof api.downloads.cancel !== "function") return;
    api.downloads.cancel(item.id);
  });
}

async function readCapture() {
  if (!api || !api.storage || !api.storage.local) return false;
  try {
    const stored = await api.storage.local.get(captureKey);
    return stored[captureKey] === true;
  } catch {
    return false;
  }
}

async function syncCapture() {
  const downloads = api && api.downloads;
  const enabled = (await readCapture()) && Boolean(downloads && downloads.onCreated);
  if (!downloads || !downloads.onCreated) return;
  if (enabled && !captureAttached) {
    downloads.onCreated.addListener(onDownloadCreated);
    captureAttached = true;
  }
  if (!enabled && captureAttached) {
    downloads.onCreated.removeListener(onDownloadCreated);
    captureAttached = false;
  }
}

installMenu();
const menu = menuAPI();
if (menu && menu.onClicked && typeof menu.onClicked.addListener === "function") {
  menu.onClicked.addListener(onMenuClick);
}
if (api && api.runtime && api.runtime.onMessage) {
  api.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== "capture-setting") return;
    syncCapture();
  });
}
syncCapture();
