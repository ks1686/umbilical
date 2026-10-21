#!/usr/bin/env node
"use strict";

const assert = require("assert");
const path = require("path");
const capture = require(path.join(
  __dirname,
  "..",
  "..",
  "Extension",
  "Resources",
  "content.js"
));

function fake(attrs) {
  return {
    getAttribute(name) {
      if (!Object.prototype.hasOwnProperty.call(attrs, name)) return null;
      return attrs[name];
    },
    hasAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name);
    },
  };
}

assert.strictEqual(capture.magnetAllowed("magnet:?xt=urn:btih:" + "ab".repeat(20)), true);
assert.strictEqual(capture.magnetAllowed("magnet:?xt=urn:btmh:1220" + "ab".repeat(32)), true);
assert.strictEqual(capture.magnetAllowed("magnet:xt=urn:btih:" + "ab".repeat(20)), false);
assert.strictEqual(capture.magnetAllowed("https://example.com/a.torrent"), false);

assert.strictEqual(
  capture.shouldIntercept(fake({ href: "https://example.com/a.zip" }), "https://example.com/a.zip"),
  true
);
assert.strictEqual(
  capture.shouldIntercept(
    fake({ href: "https://example.com/a", download: "" }),
    "https://example.com/a"
  ),
  true
);
assert.strictEqual(
  capture.shouldIntercept(
    fake({ href: "https://example.com/dl", type: "application/x-bittorrent" }),
    "https://example.com/dl"
  ),
  true
);
assert.strictEqual(
  capture.shouldIntercept(
    fake({ href: "https://example.com/index.html" }),
    "https://example.com/index.html"
  ),
  false
);
assert.strictEqual(
  capture.shouldIntercept(
    fake({ href: "javascript:alert(1)" }),
    "javascript:alert(1)"
  ),
  false
);
assert.strictEqual(
  capture.shouldIntercept(fake({ href: "file:///tmp/a.zip" }), "file:///tmp/a.zip"),
  false
);
assert.strictEqual(
  capture.shouldIntercept(
    fake({ href: "ftp://files.example.com/a.bin" }),
    "ftp://files.example.com/a.bin"
  ),
  true
);

const torrentName = capture.filenameFromLink(
  fake({ href: "https://example.com/dl", type: "application/x-bittorrent" }),
  "https://example.com/dl",
  "application/x-bittorrent"
);
assert.strictEqual(torrentName, "download.torrent");
assert.strictEqual(capture.isPlainFilename("-o"), false);
assert.ok(capture.FILE_EXTENSIONS.has("torrent"));
assert.ok(capture.FILE_EXTENSIONS.has("meta4"));

console.log("ok");
