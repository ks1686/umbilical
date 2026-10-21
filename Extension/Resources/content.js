// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in click capture. Reads only the clicked link's href, download, and type.
// Does not read page text, forms, cookies, or other nodes.

const api = globalThis.browser ?? globalThis.chrome;
const FILE_EXTENSIONS = new Set([
  "7z", "apk", "avi", "azw3", "bin", "bz2", "csv", "deb", "dmg", "doc", "docx",
  "epub", "exe", "flac", "gz", "ics", "iso", "jar", "m4a", "mka", "mkv", "mov",
  "mp3", "mp4", "msi", "odt", "ogg", "ogv", "pdf", "pkg", "ppt", "pptx", "rar",
  "rpm", "rtf", "tar", "tbz2", "tgz", "torrent", "txt", "wav", "webm", "wma",
  "wmv", "xls", "xlsx", "xz", "zip", "zst", "metalink", "meta4"
]);
const TORRENT_TYPES = new Set(["application/x-bittorrent"]);
const METALINK_TYPES = new Set([
  "application/metalink+xml",
  "application/metalink4+xml",
  "application/x-metalink+xml"
]);

let captureOn = false;
let passThrough = false;

function isPlainFilename(name) {
  if (!name || name === "." || name === "..") return false;
  if (name.length > 255) return false;
  if (name.charAt(0) === "-") return false;
  return !/[\\/\u0000\r\n]/.test(name);
}

function pathExtension(name) {
  if (!name) return "";
  const trimmed = String(name);
  const slash = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  const base = slash >= 0 ? trimmed.slice(slash + 1) : trimmed;
  const dot = base.lastIndexOf(".");
  if (dot <= 0 || dot === base.length - 1) return "";
  return base.slice(dot + 1).toLowerCase();
}

function magnetAllowed(href) {
  if (typeof href !== "string") return false;
  const lower = href.toLowerCase();
  if (!lower.startsWith("magnet:?")) return false;
  return lower.includes("xt=urn:btih:") || lower.includes("xt=urn:btmh:");
}

function resolveHref(raw, base) {
  try {
    return new URL(raw, base).href;
  } catch {
    return "";
  }
}

function filenameFromLink(anchor, urlString, mime) {
  const download = anchor.getAttribute("download");
  if (typeof download === "string" && isPlainFilename(download)) {
    return download;
  }
  let fromPath = "";
  let parsed;
  try {
    parsed = new URL(urlString);
  } catch {
    parsed = null;
  }
  if (parsed && parsed.protocol !== "magnet:") {
    const parts = parsed.pathname.split("/").filter((part) => part.length > 0);
    if (parts.length > 0) {
      let name = parts[parts.length - 1];
      try {
        name = decodeURIComponent(name);
      } catch {
        name = "";
      }
      if (isPlainFilename(name)) fromPath = name;
    }
  }
  if (TORRENT_TYPES.has(mime)) {
    return pathExtension(fromPath) === "torrent" ? fromPath : "download.torrent";
  }
  if (METALINK_TYPES.has(mime)) {
    const ext = pathExtension(fromPath);
    return ext === "metalink" || ext === "meta4" ? fromPath : "download.meta4";
  }
  return fromPath;
}

function shouldIntercept(anchor, urlString) {
  if (!urlString || urlString.charAt(0) === "-") return false;
  let parsed;
  try {
    parsed = new URL(urlString);
  } catch {
    return false;
  }
  const scheme = parsed.protocol.replace(/:$/, "").toLowerCase();
  if (scheme === "magnet") {
    return magnetAllowed(urlString);
  }
  if (scheme !== "http" && scheme !== "https" && scheme !== "ftp" && scheme !== "sftp") {
    return false;
  }
  if (anchor.hasAttribute("download")) return true;
  const mime = (anchor.getAttribute("type") || "").trim().toLowerCase();
  if (TORRENT_TYPES.has(mime) || METALINK_TYPES.has(mime)) return true;
  const downloadName = anchor.getAttribute("download");
  const hintName = typeof downloadName === "string" ? downloadName : "";
  const ext = pathExtension(hintName) || pathExtension(parsed.pathname);
  return FILE_EXTENSIONS.has(ext);
}

function sendIntercept(url, filename) {
  return new Promise((resolve) => {
    if (!api || !api.runtime || typeof api.runtime.sendMessage !== "function") {
      resolve(false);
      return;
    }
    const payload = { type: "umbilical-intercept", url };
    if (filename) payload.filename = filename;
    const finish = (reply) => resolve(reply && reply.accepted === true);
    try {
      const pending = api.runtime.sendMessage(payload, finish);
      if (pending && typeof pending.then === "function") {
        pending.then(finish).catch(() => resolve(false));
      }
    } catch {
      resolve(false);
    }
  });
}

function closestLink(target) {
  if (!target || typeof target.closest !== "function") return null;
  return target.closest("a[href]");
}

function onClick(event) {
  if (passThrough) return;
  if (!captureOn) return;
  if (event.defaultPrevented) return;
  if (event.button !== 0) return;
  if (event.altKey || event.metaKey || event.ctrlKey || event.shiftKey) return;
  const anchor = closestLink(event.target);
  if (!anchor) return;
  const rawHref = anchor.getAttribute("href");
  if (typeof rawHref !== "string" || rawHref.length === 0) return;
  const urlString = resolveHref(rawHref, globalThis.location && globalThis.location.href);
  if (!shouldIntercept(anchor, urlString)) return;
  const mime = (anchor.getAttribute("type") || "").trim().toLowerCase();
  const filename = filenameFromLink(anchor, urlString, mime);
  event.preventDefault();
  event.stopPropagation();
  sendIntercept(urlString, filename).then((accepted) => {
    if (accepted === true) return;
    passThrough = true;
    try {
      anchor.click();
    } finally {
      passThrough = false;
    }
  });
}

function loadCaptureState() {
  if (!api || !api.runtime || typeof api.runtime.sendMessage !== "function") {
    captureOn = false;
    return;
  }
  const apply = (reply) => {
    captureOn = !!(reply && reply.enabled === true);
  };
  try {
    const pending = api.runtime.sendMessage({ type: "umbilical-capture-state" }, apply);
    if (pending && typeof pending.then === "function") {
      pending.then(apply).catch(() => {
        captureOn = false;
      });
    }
  } catch {
    captureOn = false;
  }
}

if (typeof document !== "undefined" && document.addEventListener) {
  document.addEventListener("click", onClick, true);
  loadCaptureState();
  if (api && api.storage && api.storage.onChanged && api.storage.onChanged.addListener) {
    api.storage.onChanged.addListener((changes, area) => {
      if (area && area !== "local") return;
      if (!changes || !changes.captureDownloads) return;
      captureOn = changes.captureDownloads.newValue === true;
    });
  }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    FILE_EXTENSIONS,
    magnetAllowed,
    shouldIntercept,
    pathExtension,
    isPlainFilename,
    filenameFromLink,
  };
}
