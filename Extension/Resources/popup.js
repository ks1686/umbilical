// SPDX-License-Identifier: GPL-3.0-or-later
// Requests optional website access from a toolbar popup click, a user gesture.
// Safari hides the link menu until that access is granted.

const api = globalThis.browser ?? globalThis.chrome;
const allWebsites = { origins: ["<all_urls>"] };

function $(id) {
  return document.getElementById(id);
}

function setStatus(text) {
  const node = $("access-status");
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

function onGrantResult(granted) {
  const button = $("allow-access");
  if (granted === true) {
    if (button) button.disabled = true;
    setStatus("Website access is on. Right-click a link and choose Download with umbilical.");
    return;
  }
  if (button) button.disabled = false;
  setStatus("Safari did not grant website access. " + settingsHint());
}

async function requestAccess() {
  const button = $("allow-access");
  if (button) button.disabled = true;
  setStatus("");
  if (!api || !api.permissions || typeof api.permissions.request !== "function") {
    if (button) button.disabled = false;
    setStatus("Website access could not be requested. " + settingsHint());
    return;
  }
  try {
    const granted = await api.permissions.request(allWebsites);
    onGrantResult(granted === true);
  } catch {
    if (button) button.disabled = false;
    setStatus("Website access could not be requested. " + settingsHint());
  }
}

async function syncButton() {
  const granted = await hasWebsiteAccess();
  if (granted === true) {
    onGrantResult(true);
  }
}

document.addEventListener("DOMContentLoaded", () => {
  const button = $("allow-access");
  if (button) button.addEventListener("click", requestAccess);
  syncButton();
});
