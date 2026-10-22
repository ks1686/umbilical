#!/usr/bin/env python3
"""Offline checks for the release helpers."""

from __future__ import annotations

import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
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

    def test_appcast_includes_release_notes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "appcast.xml"
            note = (
                "Safari turned off the umbilical extension after this update. "
                "To turn it back on, open Safari Settings, choose Extensions, "
                "and tick umbilical."
            )
            release_tools.render_appcast(
                version="1.0.1",
                short_version="1.0.1",
                minimum="14.0",
                signature="abc123==",
                length=10,
                previous=None,
                output=output,
                pubdate="Thu, 22 Oct 2026 00:00:00 +0000",
                notes=note,
            )
            text = output.read_text(encoding="utf-8")
            self.assertIn("<description>", text)
            self.assertIn("tick umbilical.", text)
            self.assertNotIn("Umbilical", text)

    def test_release_notes_mention_safari_extension_reenable(self) -> None:
        sentence = (
            "Safari turned off the umbilical extension after this update. "
            "To turn it back on, open Safari Settings, choose Extensions, "
            "and tick umbilical."
        )
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        notes = release_tools.release_notes_path(ROOT, "1.0.1").read_text(
            encoding="utf-8"
        )
        self.assertIn("## 1.0.1", changelog)
        self.assertIn(sentence, changelog)
        self.assertIn(sentence, notes)
        self.assertNotIn("\u2014", changelog)
        self.assertNotIn("\u2013", changelog)
        self.assertNotIn("\u2014", notes)
        publish = (ROOT / "scripts" / "release" / "publish.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("docs/release-notes/${version}.md", publish)
        self.assertIn("--notes-file", publish)

    def test_stamp_extension_manifest_rewrites_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "manifest.json"
            manifest.write_text(
                '{\n  "manifest_version": 3,\n  "name": "umbilical",\n'
                '  "version": "1.1.0"\n}\n',
                encoding="utf-8",
            )
            release_tools.stamp_extension_manifest(manifest, "1.0.1")
            text = manifest.read_text(encoding="utf-8")
            self.assertIn('"version": "1.0.1"', text)
            self.assertNotIn("1.1.0", text)
            self.assertEqual(json.loads(text)["name"], "umbilical")
            release_tools.stamp_extension_manifest(manifest, "1.0.1")
            self.assertEqual(json.loads(text)["version"], "1.0.1")
            with self.assertRaises(SystemExit):
                release_tools.stamp_extension_manifest(manifest, "1.0")
            missing = Path(tmp) / "missing.json"
            with self.assertRaises(SystemExit):
                release_tools.stamp_extension_manifest(missing, "1.0.1")

    def test_source_manifest_matches_marketing_version(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        versions = re.findall(r'MARKETING_VERSION:\s*"([^"]+)"', project)
        self.assertEqual(versions, ["1.0.1", "1.0.1"])
        manifest = json.loads(
            (ROOT / "Extension" / "Resources" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(manifest["version"], "1.0.1")
        stamp = (ROOT / "scripts" / "stamp-extension-manifest.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("stamp-manifest", stamp)
        self.assertIn("MARKETING_VERSION", stamp)

    def test_previous_appcast_rejects_doctype(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            previous = Path(tmp) / "bad.xml"
            previous.write_text(
                '<!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><rss version="2.0"></rss>',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                release_tools._load_previous_items(previous, "1.2.3")

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
        self.assertNotIn("keychain-access-groups", release_ents)
        developer_ents = (ROOT / "App" / "umbilical-developer-id.entitlements").read_text(
            encoding="utf-8"
        )
        self.assertIn("keychain-access-groups", developer_ents)
        self.assertIn(release_tools.APP_ACCESS_GROUP, developer_ents)
        self.assertNotIn("$(AppIdentifierPrefix)", developer_ents)
        self.assertNotIn("*", developer_ents)
        self.assertIn("CODE_SIGN_ENTITLEMENTS: App/umbilical.entitlements", project)
        self.assertNotIn(
            "CODE_SIGN_ENTITLEMENTS: App/umbilical-developer-id.entitlements",
            project,
        )
        debug_ents = (ROOT / "App" / "umbilical-debug.entitlements").read_text(encoding="utf-8")
        self.assertIn("com.apple.security.cs.disable-library-validation", debug_ents)
        self.assertNotIn("allow-jit", debug_ents)
        self.assertNotIn("keychain-access-groups", debug_ents)
        for relative in ("Extension/Extension.entitlements", "helpers/yt-dlp.entitlements"):
            self.assertNotIn(
                "keychain-access-groups",
                (ROOT / relative).read_text(encoding="utf-8"),
            )

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
            appex = contents / "PlugIns" / "umbilicalExtension.appex"
            (appex / "Contents" / "Resources").mkdir(parents=True)
            ext_info = {
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "1.2.3",
            }
            with (appex / "Contents" / "Info.plist").open("wb") as handle:
                plistlib.dump(ext_info, handle)
            (appex / "Contents" / "Resources" / "manifest.json").write_text(
                '{"manifest_version": 3, "version": "1.2.3"}\n',
                encoding="utf-8",
            )
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
            (appex / "Contents" / "Resources" / "manifest.json").write_text(
                '{"manifest_version": 3, "version": "1.1.0"}\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                release_tools.check_built_app(app, "", signed=False)
            (appex / "Contents" / "Resources" / "manifest.json").write_text(
                '{"manifest_version": 3, "version": "1.2.3"}\n',
                encoding="utf-8",
            )
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


    def _saved_env(self, names: tuple[str, ...]) -> dict[str, str | None]:
        return {name: os.environ.get(name) for name in names}

    def _restore_env(self, saved: dict[str, str | None]) -> None:
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def test_prepare_licensing_env_overrides_file(self) -> None:
        saved = self._saved_env(("POLAR_ORGANIZATION_ID",))
        try:
            with tempfile.TemporaryDirectory() as tmp:
                dest = Path(tmp) / "Licensing.local.xcconfig"
                dest.write_text(
                    "POLAR_ORGANIZATION_ID = aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n",
                    encoding="utf-8",
                )
                os.environ["POLAR_ORGANIZATION_ID"] = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
                value = release_tools.prepare_licensing(dest)
                self.assertEqual(value, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
                self.assertIn(
                    "POLAR_ORGANIZATION_ID = bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n",
                    dest.read_text(encoding="utf-8"),
                )
                os.environ["POLAR_ORGANIZATION_ID"] = "   "
                from_file = release_tools.prepare_licensing(dest)
                self.assertEqual(from_file, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
                os.environ.pop("POLAR_ORGANIZATION_ID", None)
                missing = Path(tmp) / "Licensing.local.xcconfig"
                missing.unlink()
                with self.assertRaises(SystemExit) as caught:
                    release_tools.prepare_licensing(missing)
                self.assertIn("empty", str(caught.exception))
                dest.write_text("POLAR_ORGANIZATION_ID = not-a-uuid\n", encoding="utf-8")
                with self.assertRaises(SystemExit):
                    release_tools.prepare_licensing(dest)
        finally:
            self._restore_env(saved)

    def test_repo_from_remote(self) -> None:
        for url in (
            "git@github.com:ks1686/umbilical.git",
            "https://github.com/ks1686/umbilical.git",
            "https://github.com/ks1686/umbilical",
            "ssh://git@github.com/ks1686/umbilical.git",
            "https://github.com/ks1686/umbilical.git/",
        ):
            release_tools.assert_repo(release_tools.repo_from_remote(url))
        token_remote = "https://x-access-token:secret-token@github.com/ks1686/umbilical.git"
        parsed = release_tools.repo_from_remote(token_remote)
        self.assertEqual(parsed, "ks1686/umbilical")
        self.assertNotIn("secret-token", parsed)
        with self.assertRaises(SystemExit) as caught:
            release_tools.repo_from_remote("https://user:secret-token@gitlab.com/ks1686/umbilical.git")
        self.assertNotIn("secret-token", str(caught.exception))
        with self.assertRaises(SystemExit):
            release_tools.assert_repo(release_tools.repo_from_remote("git@github.com:other/umbilical.git"))

    def test_developer_id_identity_requires_one(self) -> None:
        text = '\n'.join(
            [
                '  1) AAAA "Apple Development: Karim (TEAM)"',
                '  2) BBBB "Developer ID Application: Karim Smires (TEAMID)"',
                "     2 valid identities found",
            ]
        )
        self.assertEqual(
            release_tools.developer_id_identity(text),
            "Developer ID Application: Karim Smires (TEAMID)",
        )
        self.assertNotIn("Developer ID Installer", release_tools.developer_id_identity(
            '  1) CCCC "Developer ID Application: Only (TEAM)"\n'
            '  2) DDDD "Developer ID Installer: Only (TEAM)"\n'
        ))
        with self.assertRaises(SystemExit):
            release_tools.developer_id_identity('  1) AAAA "Apple Development: Karim (TEAM)"\n')
        with self.assertRaises(SystemExit):
            release_tools.developer_id_identity(
                '  1) AAAA "Developer ID Application: One (TEAM)"\n'
                '  2) BBBB "Developer ID Application: Two (TEAM)"\n'
            )

    def test_sparkle_key_file_mode_and_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "umbilical.key"
            secret = "sentinel-private-seed-not-printed"
            key.write_text(secret + "\n", encoding="utf-8")
            key.chmod(0o644)
            with self.assertRaises(SystemExit) as caught:
                release_tools.check_sparkle_key(ROOT / "App" / "Info.plist", key)
            self.assertIn("mode 600", str(caught.exception))
            self.assertNotIn(secret, str(caught.exception))
            seed = base64.b64encode(os.urandom(32)).decode("ascii")
            key.write_text(seed + "\n", encoding="utf-8")
            key.chmod(0o600)
            with self.assertRaises(SystemExit) as caught:
                release_tools.check_sparkle_key(ROOT / "App" / "Info.plist", key)
            self.assertIn("does not match", str(caught.exception))
            self.assertNotIn(seed, str(caught.exception))
            key.chmod(0o400)
            with self.assertRaises(SystemExit) as caught:
                release_tools.check_sparkle_key(ROOT / "App" / "Info.plist", key)
            self.assertIn("does not match", str(caught.exception))
            link = Path(tmp) / "link.key"
            link.symlink_to(key)
            with self.assertRaises(SystemExit) as caught:
                release_tools.read_private_key_file(link)
            self.assertIn("symlink", str(caught.exception))

    def test_notary_profile_or_local_key(self) -> None:
        names = (
            "NOTARY_KEYCHAIN_PROFILE",
            "NOTARY_KEY_PATH",
            "NOTARY_KEY_ID",
            "NOTARY_ISSUER_ID",
        )
        saved = self._saved_env(names)
        try:
            for name in names:
                os.environ.pop(name, None)
            with tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp)
                (config / "keychain-profile").write_text("umbilical-notary\n", encoding="utf-8")
                args = release_tools.resolve_notary_auth(config)
                self.assertEqual(args, ["--keychain-profile", "umbilical-notary"])
                (config / "keychain-profile").unlink()
                key = config / "AuthKey.p8"
                sentinel = "SENTINEL-KEY-BYTES"
                key.write_text(
                    "-----BEGIN PRIVATE KEY-----\n" + sentinel + "\n-----END PRIVATE KEY-----\n",
                    encoding="utf-8",
                )
                key.chmod(0o644)
                with self.assertRaises(SystemExit) as caught:
                    release_tools.resolve_notary_auth(config)
                self.assertIn("mode 600", str(caught.exception))
                self.assertNotIn(sentinel, str(caught.exception))
                key.chmod(0o600)
                (config / "key-id").write_text("AB12CD34EF\n", encoding="utf-8")
                (config / "issuer-id").write_text(
                    "abcdabcd-abcd-abcd-abcd-abcdabcdabcd\n",
                    encoding="utf-8",
                )
                args = release_tools.resolve_notary_auth(config)
                self.assertEqual(
                    args,
                    [
                        "--key",
                        str(key),
                        "--key-id",
                        "AB12CD34EF",
                        "--issuer",
                        "abcdabcd-abcd-abcd-abcd-abcdabcdabcd",
                    ],
                )
                self.assertNotIn(sentinel, " ".join(args))
                os.environ["NOTARY_KEYCHAIN_PROFILE"] = "from-env"
                self.assertEqual(
                    release_tools.resolve_notary_auth(config),
                    ["--keychain-profile", "from-env"],
                )
        finally:
            self._restore_env(saved)

    def test_actions_do_not_receive_signing_material(self) -> None:
        self.assertFalse((ROOT / "scripts" / "release" / "import-developer-id.sh").exists())
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch", workflow)
        self.assertNotIn("push:", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotRegex(workflow, r"(?m)^\s*environment:")
        for banned in (
            "MACOS_SIGN_P12",
            "MACOS_NOTARY_KEY",
            "SPARKLE_ED_PRIVATE_KEY",
            "security import",
        ):
            self.assertNotIn(banned, workflow)
        for path in (ROOT / ".github" / "workflows").glob("*.yml"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("MACOS_SIGN_P12", text)
            self.assertNotIn("SPARKLE_ED_PRIVATE_KEY", text)
            self.assertNotIn("MACOS_NOTARY_KEY", text)
        release_doc = (ROOT / "docs" / "RELEASE.md").read_text(encoding="utf-8")
        for banned in (
            "MACOS_SIGN_P12",
            "MACOS_SIGN_PASSWORD",
            "MACOS_NOTARY_KEY",
            "MACOS_NOTARY_KEY_ID",
            "MACOS_NOTARY_ISSUER_ID",
            "SPARKLE_ED_PRIVATE_KEY",
            "gh secret set",
            "environment: release",
        ):
            self.assertNotIn(banned, release_doc)
        self.assertIn("wMhJbYoJtpde3xrtBBL1neu9PM5giL3OnYmE7C04OFY=", release_doc)
        self.assertIn("~/.config/genv", release_doc)
        self.assertIn("scripts/release/publish.sh", release_doc)
        publish = (ROOT / "scripts" / "release" / "publish.sh").read_text(encoding="utf-8")
        notarize = (ROOT / "scripts" / "release" / "notarize-dmg.sh").read_text(encoding="utf-8")
        for script in (publish, notarize):
            self.assertIn("GITHUB_ACTIONS", script)
            self.assertIn("MACOS_SIGN_P12", script)
            self.assertIn("MACOS_NOTARY_KEY", script)
            self.assertIn("SPARKLE_ED_PRIVATE_KEY", script)
            self.assertNotIn("security import", script)
            self.assertNotIn("b64decode", script)
            self.assertNotIn("base64", script)
        self.assertIn("gh auth status", publish)
        self.assertIn("--ed-key-file", publish)
        self.assertIn("SPARKLE_ED_KEY_FILE", publish)
        self.assertNotIn("SPARKLE_KEY_OUT", publish)
        self.assertIn('--timestamp "${dmg}"', publish)
        self.assertNotIn("--options runtime", publish)
        self.assertIn("stapler staple", notarize)
        self.assertIn("stapler validate", notarize)
        self.assertIn("spctl --assess", notarize)
        self.assertIn("notarytool submit", notarize)
        sign = (ROOT / "scripts" / "release" / "sign-bundle.sh").read_text(encoding="utf-8")
        self.assertIn("--options runtime", sign)
        self.assertIn("--timestamp", sign)
        self.assertIn("helpers/yt-dlp.entitlements", sign)
        self.assertIn("write-adhoc-app-entitlements", sign)
        self.assertIn("write-developer-id-app-entitlements", sign)
        self.assertIn("check-keychain-entitlement-files", sign)
        self.assertIn("App/umbilical-developer-id.entitlements", sign)
        self.assertIn("resolve-provisioning-profile", sign)
        self.assertIn("keychain-access-groups", sign)
        self.assertIn("resolve-provisioning-profile", publish)
        just = (ROOT / "justfile").read_text(encoding="utf-8")
        self.assertIn("scripts/release/publish.sh", just)
        for path in (ROOT / "scripts").rglob("*.sh"):
            self.assertNotIn("security import", path.read_text(encoding="utf-8"))

    def test_keychain_profile_authorizes_only_this_app(self) -> None:
        team = "AB12CD34EF"
        now = datetime(2026, 10, 16, tzinfo=timezone.utc)
        plist = {
            "TeamIdentifier": [team],
            "ExpirationDate": datetime(2030, 1, 1, tzinfo=timezone.utc),
            "Platform": ["OSX"],
            "Entitlements": {
                "com.apple.application-identifier": f"{team}.me.peapod.umbilical",
                "com.apple.developer.team-identifier": team,
                "keychain-access-groups": [f"{team}.*"],
            },
        }
        self.assertEqual(release_tools.validate_developer_id_profile(plist, now), team)
        exact = dict(plist)
        exact["Entitlements"] = dict(plist["Entitlements"])
        exact["Entitlements"]["keychain-access-groups"] = [f"{team}.me.peapod.umbilical"]
        self.assertEqual(release_tools.validate_developer_id_profile(exact, now), team)
        mac_profile = {
            "TeamIdentifier": [release_tools.APP_TEAM_ID],
            "ExpirationDate": datetime(2030, 1, 1, tzinfo=timezone.utc),
            "Platform": ["OSX"],
            "Entitlements": {
                "com.apple.application-identifier": release_tools.APP_ACCESS_GROUP,
                "com.apple.developer.team-identifier": release_tools.APP_TEAM_ID,
                "keychain-access-groups": [f"{release_tools.APP_TEAM_ID}.*"],
            },
        }
        self.assertEqual(
            release_tools.validate_developer_id_profile(mac_profile, now),
            release_tools.APP_TEAM_ID,
        )
        development = dict(plist)
        development["ProvisionedDevices"] = ["DEVICE"]
        with self.assertRaises(SystemExit):
            release_tools.validate_developer_id_profile(development, now)
        expired = dict(plist)
        expired["ExpirationDate"] = datetime(2020, 1, 1, tzinfo=timezone.utc)
        with self.assertRaises(SystemExit):
            release_tools.validate_developer_id_profile(expired, now)
        other_app = dict(plist)
        other_app["Entitlements"] = dict(plist["Entitlements"])
        other_app["Entitlements"]["com.apple.application-identifier"] = f"{team}.other.app"
        with self.assertRaises(SystemExit):
            release_tools.validate_developer_id_profile(other_app, now)
        with self.assertRaises(SystemExit):
            release_tools.access_group_for_team("short")

        build = release_tools.load_plist(ROOT / "App" / "umbilical.entitlements")
        release_tools.require_build_entitlements_omit_keychain(build)
        adhoc = release_tools.entitlements_for_adhoc(
            {"keychain-access-groups": [f"{team}.me.peapod.umbilical"], "other": True}
        )
        self.assertNotIn("keychain-access-groups", adhoc)
        self.assertEqual(adhoc["other"], True)
        developer = release_tools.load_plist(ROOT / "App" / "umbilical-developer-id.entitlements")
        self.assertEqual(
            release_tools.check_keychain_entitlement_files(build, developer),
            release_tools.APP_TEAM_ID,
        )
        signed = release_tools.entitlements_for_developer_id(developer, release_tools.APP_TEAM_ID)
        self.assertEqual(signed["keychain-access-groups"], [release_tools.APP_ACCESS_GROUP])
        with self.assertRaises(SystemExit):
            release_tools.entitlements_for_developer_id(developer, team)
        other_team = {"keychain-access-groups": [f"{team}.me.peapod.umbilical"]}
        self.assertEqual(
            release_tools.entitlements_for_developer_id(other_team, team)["keychain-access-groups"],
            [f"{team}.me.peapod.umbilical"],
        )
        extra = {
            "keychain-access-groups": [
                "$(AppIdentifierPrefix)me.peapod.umbilical",
                "$(AppIdentifierPrefix)me.peapod.other",
            ]
        }
        with self.assertRaises(SystemExit):
            release_tools.entitlements_for_developer_id(extra, team)
        with self.assertRaises(SystemExit):
            release_tools.entitlements_for_developer_id(
                {"keychain-access-groups": [f"{team}.*"]},
                team,
            )
        with self.assertRaises(SystemExit):
            release_tools.check_keychain_entitlement_files(
                {"keychain-access-groups": [release_tools.APP_ACCESS_GROUP]},
                developer,
            )
        release_tools.assert_signed_keychain_entitlement(adhoc, label="app", team_id=None)
        release_tools.assert_signed_keychain_entitlement(
            signed, label="app", team_id=release_tools.APP_TEAM_ID
        )
        with self.assertRaises(SystemExit):
            release_tools.assert_signed_keychain_entitlement(
                {"keychain-access-groups": [f"{team}.*"]},
                label="app",
                team_id=team,
            )
        with self.assertRaises(SystemExit):
            release_tools.assert_signed_keychain_entitlement(signed, label="helper", team_id=None)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            missing = root / "missing.provisionprofile"
            with self.assertRaises(SystemExit):
                release_tools.provisioning_profile_path(None, missing)
            present = root / "umbilical.provisionprofile"
            present.write_bytes(b"\x30\x82" + b"profile-bytes!!")
            self.assertEqual(release_tools.provisioning_profile_path(None, present), present)
            with self.assertRaises(SystemExit):
                release_tools.provisioning_profile_path("", present)
            with self.assertRaises(SystemExit):
                release_tools.provisioning_profile_path("line\nbreak", present)
            xml_profile = root / "decoded.plist"
            xml_profile.write_bytes(b"<?xml version='1.0'?><plist/>")
            embed = root / "App" / "embedded.provisionprofile"
            with self.assertRaises(SystemExit):
                release_tools.embed_provisioning_profile(xml_profile, embed)
            release_tools.embed_provisioning_profile(present, embed)
            self.assertEqual(embed.read_bytes(), present.read_bytes())
            self.assertEqual(embed.stat().st_mode & 0o777, 0o644)


if __name__ == "__main__":
    unittest.main()
