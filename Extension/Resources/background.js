// SPDX-License-Identifier: GPL-3.0-or-later
// Sends a URL and an optional file name to the umbilical app. Nothing else.
// Safari hides extension context menus unless the extension already has
// website access or declares activeTab. See WebExtensionContext::addItemsToContextMenu
// in WebKit. This script never injects into the page and never reads page text.

const api = globalThis.browser ?? globalThis.chrome;
const menuID = "download-with-umbilical";
const appID = "me.peapod.umbilical";

console.log("umbilical background.js loaded");

function menuAPI() {
  if (!api) return null;
  return api.contextMenus ?? api.menus ?? null;
}

function menuSpec() {
  return {
    id: menuID,
    title: "Download with umbilical",
    contexts: ["link"],
  };
}

function lastError() {
  if (!api || !api.runtime) return null;
  return api.runtime.lastError ?? null;
}

function createMenu() {
  const menu = menuAPI();
  if (!menu || typeof menu.create !== "function") return;
  const logCreate = (err) => {
    console.log("umbilical contextMenus.create lastError", err ?? lastError());
  };
  try {
    const pending = menu.create(menuSpec(), () => logCreate(lastError()));
    if (pending && typeof pending.then === "function") {
      pending.then(() => logCreate(null)).catch((err) => logCreate(err));
    }
  } catch (err) {
    logCreate(err);
  }
}

function registerMenu() {
  const menu = menuAPI();
  if (!menu || typeof menu.removeAll !== "function") {
    createMenu();
    return;
  }
  let finished = false;
  const afterRemove = () => {
    if (finished) return;
    finished = true;
    createMenu();
  };
  try {
    const pending = menu.removeAll(afterRemove);
    if (pending && typeof pending.then === "function") {
      pending.then(afterRemove).catch(afterRemove);
    }
  } catch {
    afterRemove();
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

function sendHandoff(url, filename) {
  if (!api || !api.runtime || typeof api.runtime.sendNativeMessage !== "function") {
    return;
  }
  if (typeof url !== "string" || url.length === 0 || url.length > 4096) {
    return;
  }
  const message = { url };
  if (typeof filename === "string" && isPlainFilename(filename)) {
    message.filename = filename;
  }
  api.runtime.sendNativeMessage(appID, message);
}

function onMenuClick(info) {
  if (!info || info.menuItemId !== menuID) return;
  if (typeof info.linkUrl !== "string") return;
  sendHandoff(info.linkUrl, suggestedFilename(info.linkUrl));
}

registerMenu();
const menu = menuAPI();
if (menu && menu.onClicked && typeof menu.onClicked.addListener === "function") {
  menu.onClicked.addListener(onMenuClick);
}
if (api && api.runtime) {
  if (api.runtime.onInstalled && typeof api.runtime.onInstalled.addListener === "function") {
    api.runtime.onInstalled.addListener(registerMenu);
  }
  if (api.runtime.onStartup && typeof api.runtime.onStartup.addListener === "function") {
    api.runtime.onStartup.addListener(registerMenu);
  }
}
