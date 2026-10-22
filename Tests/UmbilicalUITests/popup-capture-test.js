#!/usr/bin/env node
"use strict";

const assert = require("assert");
const path = require("path");

const store = { captureDownloads: true };
const writes = [];
const grantedOrigins = ["*://*/*"];

function safariContains(wanted, stored) {
  return wanted.every((origin) => {
    if (origin === "<all_urls>") return stored.includes("<all_urls>");
    if (origin === "*://*/*") {
      return stored.includes("*://*/*") || stored.includes("<all_urls>");
    }
    if (origin === "http://*/*") {
      return (
        stored.includes("http://*/*") ||
        stored.includes("*://*/*") ||
        stored.includes("<all_urls>")
      );
    }
    if (origin === "https://*/*") {
      return (
        stored.includes("https://*/*") ||
        stored.includes("*://*/*") ||
        stored.includes("<all_urls>")
      );
    }
    return stored.includes(origin);
  });
}

const nodes = {};
function element(id) {
  if (!nodes[id]) {
    nodes[id] = {
      id,
      checked: false,
      disabled: false,
      hidden: true,
      textContent: "",
    };
  }
  return nodes[id];
}

globalThis.document = {
  getElementById: element,
  addEventListener() {},
};

globalThis.browser = {
  storage: {
    local: {
      async get(key) {
        return { [key]: store[key] };
      },
      async set(value) {
        Object.assign(store, value);
        writes.push({ ...value });
      },
    },
  },
  permissions: {
    async getAll() {
      return { origins: grantedOrigins.slice() };
    },
    async contains({ origins }) {
      return safariContains(origins, grantedOrigins);
    },
    async request() {
      return true;
    },
  },
};

require(path.join(
  __dirname,
  "..",
  "..",
  "Extension",
  "Resources",
  "website-access.js"
));
const popup = require(path.join(
  __dirname,
  "..",
  "..",
  "Extension",
  "Resources",
  "popup.js"
));

async function main() {
  writes.length = 0;
  store.captureDownloads = true;
  grantedOrigins.splice(0, grantedOrigins.length, "*://*/*");
  await popup.syncCheckbox();
  assert.strictEqual(element("capture").checked, true);
  assert.strictEqual(store.captureDownloads, true);
  assert.strictEqual(writes.length, 0);

  writes.length = 0;
  store.captureDownloads = true;
  grantedOrigins.splice(0, grantedOrigins.length, "https://*/*");
  await popup.syncCheckbox();
  assert.strictEqual(element("capture").checked, false);
  assert.strictEqual(store.captureDownloads, true);
  assert.strictEqual(writes.length, 0);

  writes.length = 0;
  store.captureDownloads = true;
  grantedOrigins.splice(0, grantedOrigins.length, "https://example.com/*");
  await popup.syncCheckbox();
  assert.strictEqual(element("capture").checked, false);
  assert.strictEqual(store.captureDownloads, true);
  assert.strictEqual(writes.length, 0);

  writes.length = 0;
  store.captureDownloads = true;
  grantedOrigins.splice(0, grantedOrigins.length);
  await popup.syncCheckbox();
  assert.strictEqual(element("capture").checked, false);
  assert.strictEqual(store.captureDownloads, true);
  assert.strictEqual(writes.length, 0);

  writes.length = 0;
  store.captureDownloads = true;
  grantedOrigins.splice(0, grantedOrigins.length, "http://*/*", "https://*/*");
  await popup.syncCheckbox();
  assert.strictEqual(element("capture").checked, true);
  assert.strictEqual(store.captureDownloads, true);
  assert.strictEqual(writes.length, 0);

  await popup.turnCaptureOff();
  assert.strictEqual(store.captureDownloads, false);
  assert.strictEqual(writes.length, 1);
  assert.strictEqual(writes[0].captureDownloads, false);

  console.log("ok");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
