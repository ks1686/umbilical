#!/usr/bin/env node
"use strict";

const assert = require("assert");
const path = require("path");
const access = require(path.join(
  __dirname,
  "..",
  "..",
  "Extension",
  "Resources",
  "website-access.js"
));

assert.strictEqual(access.originsCoverHttpAndHttps(["*://*/*"]), true);
assert.strictEqual(access.originsCoverHttpAndHttps(["<all_urls>"]), true);
assert.strictEqual(
  access.originsCoverHttpAndHttps(["http://*/*", "https://*/*"]),
  true
);
assert.strictEqual(
  access.originsCoverHttpAndHttps(["https://*/*", "http://*/*", "file://*/*"]),
  true
);
assert.strictEqual(access.originsCoverHttpAndHttps(["https://*/*"]), false);
assert.strictEqual(access.originsCoverHttpAndHttps(["http://*/*"]), false);
assert.strictEqual(
  access.originsCoverHttpAndHttps(["https://example.com/*"]),
  false
);
assert.strictEqual(
  access.originsCoverHttpAndHttps(["http://example.com/*", "https://example.com/*"]),
  false
);
assert.strictEqual(
  access.originsCoverHttpAndHttps(["https://*/*", "http://example.com/*"]),
  false
);
assert.strictEqual(access.originsCoverHttpAndHttps([]), false);
assert.strictEqual(access.originsCoverHttpAndHttps(undefined), false);
assert.strictEqual(access.originsCoverHttpAndHttps(null), false);

function safariPermissions(stored) {
  return {
    async getAll() {
      return { origins: stored.slice() };
    },
    async contains({ origins }) {
      return origins.every((wanted) => {
        if (wanted === "<all_urls>") return stored.includes("<all_urls>");
        if (wanted === "*://*/*") {
          return stored.includes("*://*/*") || stored.includes("<all_urls>");
        }
        if (wanted === "http://*/*") {
          return (
            stored.includes("http://*/*") ||
            stored.includes("*://*/*") ||
            stored.includes("<all_urls>")
          );
        }
        if (wanted === "https://*/*") {
          return (
            stored.includes("https://*/*") ||
            stored.includes("*://*/*") ||
            stored.includes("<all_urls>")
          );
        }
        return stored.includes(wanted);
      });
    },
  };
}

async function main() {
  assert.strictEqual(
    await access.hasWebsiteAccess(safariPermissions(["*://*/*"])),
    true
  );
  assert.strictEqual(
    await access.hasWebsiteAccess(safariPermissions(["<all_urls>"])),
    true
  );
  assert.strictEqual(
    await access.hasWebsiteAccess(
      safariPermissions(["http://*/*", "https://*/*"])
    ),
    true
  );
  assert.strictEqual(
    await access.hasWebsiteAccess(safariPermissions(["https://*/*"])),
    false
  );
  assert.strictEqual(
    await access.hasWebsiteAccess(safariPermissions(["http://*/*"])),
    false
  );
  assert.strictEqual(
    await access.hasWebsiteAccess(safariPermissions(["https://example.com/*"])),
    false
  );
  assert.strictEqual(
    await access.hasWebsiteAccess(
      safariPermissions(["http://example.com/*", "https://*/*"])
    ),
    false
  );
  assert.strictEqual(await access.hasWebsiteAccess(null), false);
  assert.strictEqual(await access.hasWebsiteAccess({}), false);

  const containsOnly = {
    async contains({ origins }) {
      if (origins.length === 1 && origins[0] === "<all_urls>") return false;
      if (origins.length === 1 && origins[0] === "*://*/*") return true;
      return false;
    },
  };
  assert.strictEqual(await access.hasWebsiteAccess(containsOnly), true);

  console.log("ok");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
