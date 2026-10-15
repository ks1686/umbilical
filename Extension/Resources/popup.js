// SPDX-License-Identifier: GPL-3.0-or-later

const api = globalThis.browser ?? globalThis.chrome;
const captureKey = "captureDownloads";
const box = document.querySelector("#capture");
const note = document.querySelector("#note");

function setNote(text) {
  if (note) note.textContent = text;
}

function downloadsAvailable() {
  return Boolean(api && api.downloads && api.downloads.onCreated);
}

async function load() {
  if (!box || !api || !api.storage || !api.storage.local) return;
  let enabled = false;
  try {
    const stored = await api.storage.local.get(captureKey);
    enabled = stored[captureKey] === true;
  } catch {
    enabled = false;
  }
  if (!downloadsAvailable()) {
    box.checked = false;
    box.disabled = true;
    setNote("Safari does not let this extension see downloads. Right-click a link instead.");
    if (enabled) {
      try {
        await api.storage.local.set({ [captureKey]: false });
      } catch {
        // The menu still works when storage is unavailable.
      }
    }
    return;
  }
  box.checked = enabled;
  if (enabled) {
    setNote("New browser downloads are sent to umbilical. The browser download is cancelled after the app accepts the link.");
  }
}

async function persist(enabled) {
  await api.storage.local.set({ [captureKey]: enabled });
  if (api.runtime && typeof api.runtime.sendMessage === "function") {
    await api.runtime.sendMessage({ type: "capture-setting" });
  }
}

if (box) {
  box.addEventListener("change", async () => {
    if (!box.checked) {
      setNote("");
      try {
        await persist(false);
      } catch {
        setNote("The setting could not be saved.");
      }
      return;
    }
    if (!downloadsAvailable() || !api.permissions || typeof api.permissions.request !== "function") {
      box.checked = false;
      setNote("Safari does not let this extension see downloads. Right-click a link instead.");
      return;
    }
    let granted = false;
    try {
      granted = await api.permissions.request({ permissions: ["downloads"] });
    } catch {
      granted = false;
    }
    if (!granted) {
      box.checked = false;
      setNote("Download capture stays off.");
      return;
    }
    try {
      await persist(true);
      setNote("New browser downloads are sent to umbilical. The browser download is cancelled after the app accepts the link.");
    } catch {
      box.checked = false;
      setNote("The setting could not be saved.");
    }
  });
}

load();
