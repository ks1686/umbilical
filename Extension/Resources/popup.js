// SPDX-License-Identifier: GPL-3.0-or-later
// Popup controls. Uses activeTab for the current page URL after this click.
// Requests optional website access from a toolbar popup click, a user gesture.
// Safari hides the link menu until that access is granted.

const api = globalThis.browser ?? globalThis.chrome;
const appID = "me.peapod.umbilical";
const captureKey = "captureDownloads";
const allWebsites = { origins: ["<all_urls>"] };

function $(id) {
  return document.getElementById(id);
}

function setStatus(id, text) {
  const node = $(id);
  if (!node) return;
  if (!text) {
    node.hidden = true;
    node.textContent = "";
    return;
  }
  node.hidden = false;
  node.textContent = text;
}

function settingsHint() {
  return "Allow it in Safari Settings > Extensions > umbilical.";
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

function sendHandoff(url, filename, video) {
  return new Promise((resolve) => {
    if (!api || !api.runtime || typeof api.runtime.sendNativeMessage !== "function") {
      resolve(false);
      return;
    }
    if (typeof url !== "string" || url.length === 0 || url.length > 4096 || url.charAt(0) === "-") {
      resolve(false);
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
        resolve(reply && reply.accepted === true);
      });
      if (pending && typeof pending.then === "function") {
        pending.then((reply) => resolve(reply && reply.accepted === true)).catch(() => resolve(false));
      }
    } catch {
      resolve(false);
    }
  });
}

async function currentTabURL() {
  if (!api || !api.tabs || typeof api.tabs.query !== "function") return "";
  const tabs = await api.tabs.query({ active: true, currentWindow: true });
  const tab = tabs && tabs[0];
  return tab && typeof tab.url === "string" ? tab.url : "";
}

async function downloadPage() {
  setStatus("page-status", "");
  try {
    const url = await currentTabURL();
    if (!url) {
      setStatus("page-status", "This page URL is not available. Click the toolbar button on a web page.");
      return;
    }
    const accepted = await sendHandoff(url, suggestedFilename(url), true);
    if (accepted !== true) {
      setStatus("page-status", "The app did not accept that page. Confirm the sheet if it is open, or try again.");
    }
  } catch {
    setStatus("page-status", "The page could not be sent.");
  }
}

async function captureIsOn() {
  if (!api || !api.storage || !api.storage.local) return false;
  const stored = await api.storage.local.get(captureKey);
  return stored && stored[captureKey] === true;
}

async function hasWebsiteAccess() {
  if (!api || !api.permissions || typeof api.permissions.contains !== "function") {
    return false;
  }
  try {
    return await api.permissions.contains(allWebsites);
  } catch {
    return false;
  }
}

async function setCapture(enabled) {
  if (api && api.storage && api.storage.local) {
    const value = {};
    value[captureKey] = enabled === true;
    await api.storage.local.set(value);
  }
}

function onGrantResult(granted) {
  const button = $("allow-access");
  if (granted === true) {
    if (button) button.disabled = true;
    setStatus("access-status", "Website access is on. Right-click a link and choose Download with umbilical.");
    return;
  }
  if (button) button.disabled = false;
  setStatus("access-status", "Safari did not grant website access. " + settingsHint());
}

async function requestAccess() {
  const button = $("allow-access");
  if (button) button.disabled = true;
  setStatus("access-status", "");
  if (!api || !api.permissions || typeof api.permissions.request !== "function") {
    if (button) button.disabled = false;
    setStatus("access-status", "Website access could not be requested. " + settingsHint());
    return;
  }
  try {
    const granted = await api.permissions.request(allWebsites);
    onGrantResult(granted === true);
    await syncCheckbox();
  } catch {
    if (button) button.disabled = false;
    setStatus("access-status", "Website access could not be requested. " + settingsHint());
  }
}

async function turnCaptureOn() {
  if (!api || !api.permissions || typeof api.permissions.request !== "function") {
    throw new Error("permissions");
  }
  const granted = await api.permissions.request(allWebsites);
  if (granted !== true) {
    return false;
  }
  await setCapture(true);
  onGrantResult(true);
  return true;
}

async function turnCaptureOff() {
  await setCapture(false);
  // Keep website access so the link menu still appears. Remove it in Safari Settings.
}

async function syncCheckbox() {
  const box = $("capture");
  if (!box) return;
  const enabled = await captureIsOn();
  const granted = await hasWebsiteAccess();
  box.checked = enabled === true && granted === true;
  if (enabled && !granted) {
    await setCapture(false);
    box.checked = false;
  }
}

async function syncAccessButton() {
  const granted = await hasWebsiteAccess();
  if (granted === true) {
    onGrantResult(true);
  }
}

async function onCaptureChange(event) {
  const box = event.target;
  setStatus("capture-status", "");
  if (box.checked) {
    try {
      const granted = await turnCaptureOn();
      box.checked = granted === true;
      if (!granted) {
        setStatus("capture-status", "Safari did not grant website access. Interception stays off.");
      }
    } catch {
      box.checked = false;
      setStatus("capture-status", "Website access could not be requested.");
    }
    return;
  }
  try {
    await turnCaptureOff();
  } catch {
    setStatus(
      "capture-status",
      "Interception is off. Remove website access in Safari Settings if you no longer want the link menu."
    );
  }
}

document.addEventListener("DOMContentLoaded", () => {
  const access = $("allow-access");
  if (access) access.addEventListener("click", requestAccess);
  const page = $("download-page");
  if (page) page.addEventListener("click", downloadPage);
  const box = $("capture");
  if (box) box.addEventListener("change", onCaptureChange);
  syncAccessButton();
  syncCheckbox();
});
