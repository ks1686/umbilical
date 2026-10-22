// SPDX-License-Identifier: GPL-3.0-or-later
// Safari may store an all-websites grant as *://*/* or as http://*/* plus
// https://*/*. permissions.contains({ origins: ["<all_urls>"] }) is then false.
// Count access as granted only when both http and https are fully covered.

(function (root) {
  const allURLs = "<all_urls>";
  const allSchemes = "*://*/*";
  const allHTTP = "http://*/*";
  const allHTTPS = "https://*/*";

  function originCoversAllHTTP(origin) {
    return origin === allURLs || origin === allSchemes || origin === allHTTP;
  }

  function originCoversAllHTTPS(origin) {
    return origin === allURLs || origin === allSchemes || origin === allHTTPS;
  }

  function originsCoverHttpAndHttps(origins) {
    if (!Array.isArray(origins)) return false;
    let http = false;
    let https = false;
    for (let i = 0; i < origins.length; i += 1) {
      const origin = origins[i];
      if (typeof origin !== "string") continue;
      if (originCoversAllHTTP(origin)) http = true;
      if (originCoversAllHTTPS(origin)) https = true;
      if (http && https) return true;
    }
    return false;
  }

  async function permissionContains(permissions, origins) {
    if (!permissions || typeof permissions.contains !== "function") return false;
    if (!Array.isArray(origins) || origins.length === 0) return false;
    try {
      return (await permissions.contains({ origins })) === true;
    } catch {
      return false;
    }
  }

  async function hasWebsiteAccess(permissions) {
    if (!permissions) return false;
    if (typeof permissions.getAll === "function") {
      try {
        const all = await permissions.getAll();
        if (originsCoverHttpAndHttps(all && all.origins)) return true;
      } catch {
        // Fall through to contains(). Safari may omit getAll.
      }
    }
    if (await permissionContains(permissions, [allURLs])) return true;
    if (await permissionContains(permissions, [allSchemes])) return true;
    if (await permissionContains(permissions, [allHTTP, allHTTPS])) return true;
    const http = await permissionContains(permissions, [allHTTP]);
    const https = await permissionContains(permissions, [allHTTPS]);
    return http === true && https === true;
  }

  const api = {
    allURLs,
    allSchemes,
    allHTTP,
    allHTTPS,
    originsCoverHttpAndHttps,
    hasWebsiteAccess,
  };

  root.umbilicalWebsiteAccess = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
