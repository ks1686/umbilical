#!/usr/bin/env python3
"""Offline checks for the release helpers."""

from __future__ import annotations

import base64
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_tools

ROOT = Path(__file__).resolve().parents[2]


class ReleaseToolsTest(unittest.TestCase):
    def test_tag_version(self) -> None:
        self.assertEqual(release_tools.version_from_tag("v0.0.1"), "0.0.1")
        self.assertEqual(release_tools.version_from_tag("v1.2.3"), "1.2.3")
        with self.assertRaises(SystemExit):
            release_tools.version_from_tag("v1.2")
        with self.assertRaises(SystemExit):
            release_tools.version_from_tag("1.2.3")

    def test_repo_guard(self) -> None:
        release_tools.assert_repo("ks1686/umbilical")
        with self.assertRaises(SystemExit):
            release_tools.assert_repo("someone/umbilical")

    def test_organization_id_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "Licensing.local.xcconfig"
            release_tools.write_licensing_xcconfig(
                "ABCDABCD-ABCD-ABCD-ABCD-ABCDABCDABCD",
                dest,
            )
            text = dest.read_text(encoding="utf-8")
            self.assertIn(
                "POLAR_ORGANIZATION_ID = abcdabcd-abcd-abcd-abcd-abcdabcdabcd\n",
                text,
            )
            self.assertNotIn("access token value", text.lower())
        for raw in ("", "   ", "$(POLAR_ORGANIZATION_ID)", "not-a-uuid"):
            with self.assertRaises(SystemExit):
                release_tools.normalize_organization_id(raw)

    def test_generated_seed_matches_openssl(self) -> None:
        private_der = subprocess.check_output(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-outform", "DER"]
        )
        self.assertTrue(private_der.startswith(release_tools.PKCS8_SEED_PREFIX))
        seed = private_der[len(release_tools.PKCS8_SEED_PREFIX) :]
        self.assertEqual(len(seed), 32)
        derived = release_tools.ed25519_public_key(base64.b64encode(seed).decode("ascii"))
        public_der = subprocess.check_output(
            ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
            input=private_der,
        )
        expected = base64.b64encode(public_der[-32:]).decode("ascii")
        self.assertEqual(derived, expected)

    def test_older_export_uses_trailing_public_key(self) -> None:
        public = os.urandom(32)
        blob = os.urandom(64) + public
        derived = release_tools.ed25519_public_key(base64.b64encode(blob).decode("ascii"))
        self.assertEqual(derived, base64.b64encode(public).decode("ascii"))
        with self.assertRaises(SystemExit):
            release_tools.ed25519_public_key(base64.b64encode(os.urandom(64)).decode("ascii"))

    def test_sparkle_key_matches_plist_and_hides_secret(self) -> None:
        private_der = subprocess.check_output(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-outform", "DER"]
        )
        seed = private_der[len(release_tools.PKCS8_SEED_PREFIX) :]
        public = release_tools.ed25519_public_key(base64.b64encode(seed).decode("ascii"))
        secret = base64.b64encode(seed).decode("ascii")
        release_tools.assert_private_key_matches(secret + "\n", public)
        with self.assertRaises(SystemExit) as caught:
            release_tools.assert_private_key_matches(secret, release_tools.PUBLIC_ED_KEY)
        message = str(caught.exception)
        self.assertNotIn(secret, message)
        self.assertIn("does not match", message)

    def test_appcast_replaces_same_version_and_keeps_older_items(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dmg = root / "umbilical-1.2.3.dmg"
            dmg.write_bytes(b"dmg-bytes")
            signature = root / "sig.txt"
            signature.write_text(
                f'sparkle:edSignature="abc123==" length="{dmg.stat().st_size}"\n',
                encoding="utf-8",
            )
            previous = root / "previous.xml"
            release_tools.render_appcast(
                version="1.0.0",
                short_version="1.0.0",
                minimum="14.0",
                signature="oldsig==",
                length=10,
                previous=None,
                output=previous,
                pubdate="Wed, 01 Jan 2020 00:00:00 +0000",
            )
            stale = root / "stale.xml"
            release_tools.render_appcast(
                version="1.2.3",
                short_version="1.2.3",
                minimum="14.0",
                signature="stale==",
                length=10,
                previous=previous,
                output=stale,
                pubdate="Thu, 01 Jan 2026 00:00:00 +0000",
            )
            output = root / "appcast.xml"
            release_tools.render_appcast(
                version="1.2.3",
                short_version="1.2.3",
                minimum="14.0",
                signature="abc123==",
                length=dmg.stat().st_size,
                previous=stale,
                output=output,
                pubdate="Thu, 15 Oct 2026 00:00:00 +0000",
            )
            text = output.read_text(encoding="utf-8")
            self.assertEqual(text.count("<sparkle:version>1.2.3</sparkle:version>"), 1)
            self.assertEqual(text.count("<sparkle:version>1.0.0</sparkle:version>"), 1)
            self.assertLess(
                text.index("<sparkle:version>1.2.3</sparkle:version>"),
                text.index("<sparkle:version>1.0.0</sparkle:version>"),
            )
            self.assertIn('sparkle:edSignature="abc123=="', text)
            self.assertIn(release_tools.FEED_URL, text)
            self.assertIn(release_tools.dmg_url("1.2.3"), text)
            self.assertNotIn("stale==", text)
            self.assertIn("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", text)

    def test_pubdate_uses_english_names(self) -> None:
        text = release_tools.rfc822_now()
        self.assertRegex(
            text,
            r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} "
            r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
            r"[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000$",
        )

    def test_cask_draft_matches_renderer(self) -> None:
        draft = (ROOT / "docs" / "homebrew" / "umbilical.rb").read_text(encoding="utf-8")
        expected = release_tools.render_cask("0.0.1", "0" * 64, draft_header=True)
        self.assertEqual(draft, expected)
        release = release_tools.render_cask("1.2.3", "ab" * 32, draft_header=False)
        for line in (
            'cask "umbilical" do',
            'sha256 "abababababababababababababababababababababababababababababababab"',
            "auto_updates true",
            'depends_on macos: ">= :sonoma"',
            'url "https://github.com/ks1686/umbilical/releases/download/v#{version}/umbilical-#{version}.dmg"',
            'app "umbilical.app"',
            "zap trash: [",
        ):
            self.assertIn(line, release)
        self.assertNotIn("Do not push", release)

    def test_source_pins(self) -> None:
        info = release_tools.load_plist(ROOT / "App" / "Info.plist")
        self.assertEqual(info["SUFeedURL"], release_tools.FEED_URL)
        self.assertEqual(info["SUPublicEDKey"], release_tools.PUBLIC_ED_KEY)
        self.assertIs(info["SUEnableAutomaticChecks"], True)
        self.assertIs(info["SUVerifyUpdateBeforeExtraction"], True)
        self.assertIs(info["SURequireSignedFeed"], True)
        self.assertEqual(info["SUScheduledCheckInterval"], 86400)
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn('exactVersion: 2.9.6', project)
        self.assertIn('macOS: "14.0"', project)
        fetch = (ROOT / "scripts" / "release" / "fetch-sparkle-tools.sh").read_text(encoding="utf-8")
        self.assertIn(release_tools.SPARKLE_SPM_SHA256, fetch)
        self.assertIn(release_tools.SPARKLE_VERSION, fetch)
        release_ents = (ROOT / "App" / "umbilical.entitlements").read_text(encoding="utf-8")
        self.assertNotIn("get-task-allow", release_ents)
        self.assertNotIn("disable-library-validation", release_ents)
        debug_ents = (ROOT / "App" / "umbilical-debug.entitlements").read_text(encoding="utf-8")
        self.assertIn("com.apple.security.cs.disable-library-validation", debug_ents)
        self.assertNotIn("allow-jit", debug_ents)

    def test_built_app_checks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "umbilical.app"
            contents = app / "Contents"
            (contents / "Helpers").mkdir(parents=True)
            (contents / "PlugIns").mkdir()
            sparkle = contents / "Frameworks" / "Sparkle.framework" / "Versions" / "B"
            (sparkle / "XPCServices").mkdir(parents=True)
            (sparkle / "Autoupdate").write_bytes(b"")
            (sparkle / "XPCServices" / "Downloader.xpc").mkdir()
            (sparkle / "XPCServices" / "Installer.xpc").mkdir()
            (sparkle / "Updater.app").mkdir()
            (contents / "Helpers" / "aria2c").write_bytes(b"")
            (contents / "Helpers" / "yt-dlp").write_bytes(b"")
            (contents / "Helpers" / "umb-watch").write_bytes(b"")
            (contents / "PlugIns" / "umbilicalExtension.appex").mkdir()
            info = {
                "SUFeedURL": release_tools.FEED_URL,
                "SUPublicEDKey": release_tools.PUBLIC_ED_KEY,
                "SUEnableAutomaticChecks": True,
                "SUVerifyUpdateBeforeExtraction": True,
                "SURequireSignedFeed": True,
                "SUScheduledCheckInterval": 86400,
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "1.2.3",
                "LSMinimumSystemVersion": "14.0",
                "PolarOrganizationID": "$(POLAR_ORGANIZATION_ID)",
            }
            with (contents / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            release_tools.check_built_app(app, "", signed=False)
            info["PolarOrganizationID"] = "abcdabcd-abcd-abcd-abcd-abcdabcdabcd"
            with (contents / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            previous = os.environ.get("POLAR_ORGANIZATION_ID")
            os.environ["POLAR_ORGANIZATION_ID"] = "ABCDABCD-ABCD-ABCD-ABCD-ABCDABCDABCD"
            try:
                release_tools.check_built_app(app, "1.2.3", signed=True)
                os.environ["POLAR_ORGANIZATION_ID"] = ""
                with self.assertRaises(SystemExit):
                    release_tools.check_built_app(app, "1.2.3", signed=True)
            finally:
                if previous is None:
                    os.environ.pop("POLAR_ORGANIZATION_ID", None)
                else:
                    os.environ["POLAR_ORGANIZATION_ID"] = previous


if __name__ == "__main__":
    unittest.main()
