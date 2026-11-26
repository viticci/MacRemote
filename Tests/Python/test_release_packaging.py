import os
import pathlib
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
import warnings
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGE_SCRIPT = ROOT / "script" / "package_release.sh"
VERIFY_SCRIPT = ROOT / "script" / "verify_release.sh"
BUILD_SCRIPT = ROOT / "script" / "build_and_run.sh"
INSTALL_TRANSACTION_SCRIPT = ROOT / "script" / "install_app_transaction.sh"
RELEASE_TRANSACTION_SCRIPT = ROOT / "script" / "release_asset_transaction.sh"
ZIP_VALIDATOR = ROOT / "script" / "validate_release_zip.py"


class ReleasePackagingTests(unittest.TestCase):
    def run_script(self, script: pathlib.Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(script), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"},
        )

    def test_release_scripts_have_valid_shell_syntax(self) -> None:
        for script in (
            PACKAGE_SCRIPT,
            VERIFY_SCRIPT,
            BUILD_SCRIPT,
            INSTALL_TRANSACTION_SCRIPT,
            RELEASE_TRANSACTION_SCRIPT,
        ):
            result = subprocess.run(
                ["/bin/bash", "-n", str(script)],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_distribution_mode_is_strict_by_default(self) -> None:
        text = PACKAGE_SCRIPT.read_text()
        self.assertIn('LOCAL_SIGNING=0', text)
        self.assertIn('Developer ID Application:', text)
        self.assertIn('notarytool submit', text)
        self.assertIn('stapler staple', text)
        self.assertIn('export DEVELOPER_DIR="/Library/Developer/CommandLineTools"', text)
        self.assertIn('--scratch-path "$RELEASE_SCRATCH_DIR"', text)
        self.assertIn('--arch arm64', text)
        self.assertIn('--arch x86_64', text)
        self.assertIn('/bin/rm -rf "$RELEASE_SCRATCH_DIR"', text)
        self.assertIn('git status --porcelain', text)
        self.assertIn('/usr/bin/cmp -s "$BUILD_BINARY" "$APP_BINARY"', text)
        self.assertIn('source revision changed while the release was building', text)
        self.assertIn('checkout changed while the release was building', text)
        self.assertIn('PRE_VERIFY_MODE="signed"', text)
        self.assertIn('FINAL_VERIFY_MODE="distribution"', text)
        self.assertNotIn('--private-beta', text)
        self.assertIn('GATEKEEPER="local-only; Gatekeeper not assessed."', text)

        preflight = text.index('--mode "$PRE_VERIFY_MODE"')
        notarize = text.index('notarytool submit')
        final = text.index('--mode "$FINAL_VERIFY_MODE"')
        checksum = text.index('ARTIFACT_SHA256=')
        publish = text.rindex('release_transaction_publish')
        self.assertLess(preflight, notarize)
        self.assertLess(notarize, final)
        self.assertLess(final, checksum)
        self.assertLess(checksum, publish)
        self.assertIn('STAGED_ARTIFACT_PATH=', text)
        self.assertNotIn('/bin/rm -f "$ARTIFACT_PATH" "$CHECKSUM_PATH" "$INFO_PATH"', text)
        self.assertIn("release_transaction_recover_if_needed", text)
        self.assertIn("release_transaction_publish", text)
        self.assertIn("release_transaction_restore", text)

    def test_verifier_checks_distribution_contract(self) -> None:
        text = VERIFY_SCRIPT.read_text()
        for expected in (
            "MacRemoteBuildConfiguration",
            "MacRemoteSourceRevision",
            "MacRemoteConnectorIcon128.png",
            "MacRemoteConnectorIcon256.png",
            "MacRemoteConnectorIcon64.png",
            "default.metallib",
            "MacRemoteWidget.html",
            "cloudflared",
            "codesign --verify --deep --strict",
            "flags=.*[(,]runtime[,)]",
            "Developer ID Application:",
            "stapler validate",
            "spctl --assess",
            '== *arm64*',
            '== *x86_64*',
        ):
            self.assertIn(expected, text)

    def test_verifier_checks_each_macho_slice_deployment_target(self) -> None:
        text = VERIFY_SCRIPT.read_text()
        self.assertIn("for architecture in arm64 x86_64", text)
        self.assertIn('/usr/bin/vtool -arch "$architecture" -show-build', text)
        self.assertIn("$architecture slice does not target macOS", text)
        self.assertIn("$architecture slice does not have a 26.0 deployment target", text)

    def test_release_app_carries_the_mit_license_notice(self) -> None:
        # The MIT License requires its notice in every copy, so the packager
        # copies LICENSE into the app before signing and the verifier refuses
        # an app without it.
        text = PACKAGE_SCRIPT.read_text()
        copy = '/usr/bin/ditto "$ROOT_DIR/LICENSE" "$APP_RESOURCES/LICENSE"'
        self.assertTrue(copy in text, "package_release.sh does not copy LICENSE into the app")
        self.assertLess(text.index(copy), text.index("/usr/bin/codesign --force"))

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        app = pathlib.Path(directory.name) / "MacRemote.app"
        resources = app / "Contents" / "Resources"
        module = resources / "MacRemote_MacRemote.bundle" / "Contents" / "Resources"
        for relative in (
            "default.metallib",
            "MacRemoteWidget.html",
            "Skills/macremote/SKILL.md",
            "ConnectedAppIcons/MANIFEST.json",
            "ConnectedAppIcons/THIRD-PARTY-NOTICES.md",
        ):
            (module / relative).parent.mkdir(parents=True, exist_ok=True)
            (module / relative).write_text("fixture")
        for name in (
            "AppIcon.icns",
            "Assets.car",
            "Favicon.ico",
            "Favicon.png",
            "MacRemoteConnectorIcon.png",
            "MacRemoteConnectorIcon128.png",
            "MacRemoteConnectorIcon256.png",
            "MacRemoteConnectorIcon64.png",
        ):
            (resources / name).write_text("fixture")
        executable = app / "Contents" / "MacOS" / "MacRemote"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\n")
        executable.chmod(0o755)
        with (app / "Contents" / "Info.plist").open("wb") as output:
            plistlib.dump(
                {
                    "CFBundleExecutable": "MacRemote",
                    "CFBundleIdentifier": "com.macstories.MacRemote",
                    "CFBundlePackageType": "APPL",
                    "LSMinimumSystemVersion": "26.0",
                    "CFBundleIconName": "AppIcon",
                    "MacRemoteBuildConfiguration": "release",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "18",
                    "MacRemoteSourceRevision": "0" * 40,
                },
                output,
            )

        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(app))
        self.assertEqual(result.returncode, 1)
        self.assertIn("MIT license notice is missing", result.stderr)

        shutil.copy(ROOT / "LICENSE", resources / "LICENSE")
        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(app))
        self.assertNotIn("MIT license notice is missing", result.stderr)
        # The fixture passes the license check and stops at the next one.
        self.assertIn("main executable is not Mach-O code", result.stderr)

    def write_archive(self, entries: list[tuple[str, bytes]]) -> pathlib.Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        archive = pathlib.Path(directory.name) / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as output:
            for name, content in entries:
                output.writestr(name, content)
        return archive

    def test_verifier_rejects_unexpected_root_payload_before_extraction(self) -> None:
        archive = self.write_archive(
            [("MacRemote.app/", b""), ("unexpected.txt", b"payload")]
        )
        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected archive entry: unexpected.txt", result.stderr)

    def test_verifier_rejects_archive_path_traversal_before_extraction(self) -> None:
        archive = self.write_archive(
            [("MacRemote.app/", b""), ("MacRemote.app/../escape", b"payload")]
        )
        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsafe archive path", result.stderr)

    def test_verifier_rejects_duplicate_archive_entries(self) -> None:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            archive = self.write_archive(
                [("MacRemote.app/", b""), ("MacRemote.app/", b"")]
            )
        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate archive entry", result.stderr)

    def test_verifier_rejects_symbolic_links_after_extraction(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        archive = pathlib.Path(directory.name) / "fixture.zip"
        link = zipfile.ZipInfo("MacRemote.app/Contents")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("MacRemote.app/", b"")
            output.writestr(link, "/Applications/MacRemote.app/Contents")

        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("zip contains a symbolic link entry", result.stderr)

    def test_verifier_rejects_special_entries_before_extraction(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        archive = pathlib.Path(directory.name) / "fixture.zip"
        fifo = zipfile.ZipInfo("MacRemote.app/Contents/fifo")
        fifo.create_system = 3
        fifo.external_attr = (stat.S_IFIFO | 0o600) << 16
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("MacRemote.app/", b"")
            output.writestr(fifo, b"")

        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported special entry", result.stderr)

    def test_verifier_rejects_casefolded_and_unicode_name_collisions(self) -> None:
        variants = (
            ("MacRemote.app/Contents/Info.plist", "MacRemote.app/contents/info.plist"),
            ("MacRemote.app/Resources/caf\N{LATIN SMALL LETTER E WITH ACUTE}", "MacRemote.app/Resources/cafe\N{COMBINING ACUTE ACCENT}"),
        )
        for first, second in variants:
            with self.subTest(first=first, second=second):
                archive = self.write_archive(
                    [("MacRemote.app/", b""), (first, b"one"), (second, b"two")]
                )
                result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
                self.assertEqual(result.returncode, 1)
                self.assertIn("colliding archive names", result.stderr)

    def test_verifier_rejects_excessive_entry_count(self) -> None:
        entries = [("MacRemote.app/", b"")]
        entries.extend(
            (f"MacRemote.app/Contents/item-{index}", b"") for index in range(4096)
        )
        archive = self.write_archive(entries)
        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("too many entries", result.stderr)

    def test_verifier_rejects_excessive_declared_expanded_size(self) -> None:
        archive = self.write_archive(
            [("MacRemote.app/", b""), ("MacRemote.app/Contents/payload", b"x")]
        )
        data = bytearray(archive.read_bytes())
        central_offset = data.find(b"PK\x01\x02", 1)
        self.assertGreater(central_offset, 0)
        struct.pack_into("<I", data, central_offset + 24, 1024 * 1024 * 1024 + 1)
        archive.write_bytes(data)

        result = self.run_script(VERIFY_SCRIPT, "--mode", "local", str(archive))
        self.assertEqual(result.returncode, 1)
        self.assertIn("too much expanded data", result.stderr)

    def test_invalid_version_fails_before_build(self) -> None:
        result = self.run_script(PACKAGE_SCRIPT, "--version", "one", "--local-signing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("version must use a numeric two- or three-part form", result.stderr)

    def test_allow_dirty_requires_local_signing(self) -> None:
        result = self.run_script(PACKAGE_SCRIPT, "--allow-dirty")
        self.assertEqual(result.returncode, 1)
        self.assertIn("valid only with --local-signing", result.stderr)

    def test_build_script_stages_release_identity_assets_and_version(self) -> None:
        text = BUILD_SCRIPT.read_text()
        self.assertIn("CFBundleShortVersionString", text)
        self.assertIn("CFBundleVersion", text)
        self.assertIn("MacRemoteConnectorIcon128.png", text)
        self.assertIn("MacRemoteConnectorIcon256.png", text)
        self.assertIn("MacRemoteConnectorIcon64.png", text)

    def test_every_bundle_ships_the_layered_icon_and_names_it(self) -> None:
        # Assets.car without CFBundleIconName silently falls back to the flat icon.
        for script in (BUILD_SCRIPT, PACKAGE_SCRIPT, VERIFY_SCRIPT):
            text = script.read_text()
            self.assertIn("Assets.car", text, script.name)
            self.assertIn("CFBundleIconName", text, script.name)

    def test_build_script_replaces_a_clean_verified_staging_bundle(self) -> None:
        text = BUILD_SCRIPT.read_text()
        self.assertIn(
            '"$ROOT_DIR/script/install_app_transaction.sh" "$APP_BUNDLE" "$INSTALL_BUNDLE"',
            text,
        )
        installer = INSTALL_TRANSACTION_SCRIPT.read_text()
        self.assertIn('STAGING_BUNDLE="$TARGET_BUNDLE.new"', installer)
        self.assertIn('PREVIOUS_BUNDLE="$TARGET_BUNDLE.previous"', installer)
        self.assertIn('codesign --verify --deep --strict', installer)
        self.assertIn('/usr/bin/diff -q -r "$SOURCE_BUNDLE" "$bundle"', installer)
        self.assertNotIn('rm -rf "$TARGET_BUNDLE"\n/bin/mv "$STAGING_BUNDLE"', installer)

    def test_build_script_verifies_the_running_executable_path(self) -> None:
        text = BUILD_SCRIPT.read_text()
        self.assertIn('expected_path="$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME"', text)
        self.assertIn('/bin/ps -p "$pid" -o comm=', text)
        self.assertIn('[[ "$process_path" == "$expected_path" ]]', text)
        verify_case = text.index('--verify|verify)')
        self.assertGreater(text.index('verify_running_install', verify_case), verify_case)

    def make_signed_app(self, path: pathlib.Path, marker: str) -> None:
        executable = path / "Contents" / "MacOS" / "MacRemote"
        resources = path / "Contents" / "Resources"
        resources.mkdir(parents=True)
        executable.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)
        (resources / "marker.txt").write_text(marker, encoding="utf-8")
        with (path / "Contents" / "Info.plist").open("wb") as output:
            plistlib.dump(
                {
                    "CFBundleExecutable": "MacRemote",
                    "CFBundleIdentifier": "com.macstories.MacRemote.test",
                    "CFBundlePackageType": "APPL",
                },
                output,
            )
        result = subprocess.run(
            ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(path)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_install_transaction_restores_previous_app_after_each_failure_point(self) -> None:
        for failure_point in ("after_backup", "after_swap", "after_verify"):
            with self.subTest(failure_point=failure_point), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                source = root / "source.app"
                target = root / "MacRemote.app"
                self.make_signed_app(source, "new")
                self.make_signed_app(target, "old")
                result = subprocess.run(
                    [str(INSTALL_TRANSACTION_SCRIPT), str(source), str(target)],
                    text=True,
                    capture_output=True,
                    check=False,
                    env={**os.environ, "MACREMOTE_TEST_FAIL_INSTALL_STEP": failure_point},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(
                    (target / "Contents" / "Resources" / "marker.txt").read_text(),
                    "old",
                )
                self.assertFalse(pathlib.Path(str(target) + ".new").exists())
                self.assertFalse(pathlib.Path(str(target) + ".previous").exists())
                self.assertFalse((root / ".MacRemote.app.install-transaction").exists())

    def test_install_transaction_commits_verified_app_and_cleans_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.app"
            target = root / "MacRemote.app"
            self.make_signed_app(source, "new")
            self.make_signed_app(target, "old")
            result = subprocess.run(
                [str(INSTALL_TRANSACTION_SCRIPT), str(source), str(target)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (target / "Contents" / "Resources" / "marker.txt").read_text(),
                "new",
            )
            self.assertFalse(pathlib.Path(str(target) + ".previous").exists())

    def test_install_transaction_keeps_committed_app_if_cleanup_is_interrupted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.app"
            target = root / "MacRemote.app"
            self.make_signed_app(source, "new")
            self.make_signed_app(target, "old")
            result = subprocess.run(
                [str(INSTALL_TRANSACTION_SCRIPT), str(source), str(target)],
                text=True,
                capture_output=True,
                check=False,
                env={**os.environ, "MACREMOTE_TEST_FAIL_INSTALL_STEP": "after_commit"},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(
                (target / "Contents" / "Resources" / "marker.txt").read_text(),
                "new",
            )
            self.assertFalse(pathlib.Path(str(target) + ".previous").exists())
            self.assertFalse((root / ".MacRemote.app.install-transaction").exists())

    def test_install_transaction_restores_previous_app_on_signal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.app"
            target = root / "MacRemote.app"
            self.make_signed_app(source, "new")
            self.make_signed_app(target, "old")
            result = subprocess.run(
                [str(INSTALL_TRANSACTION_SCRIPT), str(source), str(target)],
                text=True,
                capture_output=True,
                check=False,
                env={**os.environ, "MACREMOTE_TEST_SIGNAL_INSTALL_STEP": "after_swap"},
            )
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(
                (target / "Contents" / "Resources" / "marker.txt").read_text(),
                "old",
            )
            self.assertFalse(pathlib.Path(str(target) + ".new").exists())
            self.assertFalse(pathlib.Path(str(target) + ".previous").exists())
            self.assertFalse((root / ".MacRemote.app.install-transaction").exists())

    def run_release_transaction(
        self,
        root: pathlib.Path,
        failure_after: int | None,
        signal_after: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        stage = root / "stage"
        stage.mkdir(exist_ok=True)
        for index in range(3):
            (stage / f"new-{index}").write_text(f"new-{index}", encoding="utf-8")
        targets = [root / f"asset-{index}" for index in range(3)]
        script = f'''set -euo pipefail
RELEASE_TRANSACTION_ACTIVE=0
source {str(RELEASE_TRANSACTION_SCRIPT)!r}
targets=({" ".join(repr(str(path)) for path in targets)})
cleanup() {{
  code=$?
  if [[ $RELEASE_TRANSACTION_ACTIVE -eq 1 ]]; then
    release_transaction_restore {str(root)!r} release-set "${{targets[@]}}" || code=1
  fi
  return "$code"
}}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
release_transaction_publish {str(root)!r} release-set \\
  {str(stage / "new-0")!r} {str(targets[0])!r} \\
  {str(stage / "new-1")!r} {str(targets[1])!r} \\
  {str(stage / "new-2")!r} {str(targets[2])!r}
'''
        environment = dict(os.environ)
        if failure_after is not None:
            environment["MACREMOTE_TEST_FAIL_AFTER_PUBLISH_RENAME"] = str(failure_after)
        if signal_after is not None:
            environment["MACREMOTE_TEST_SIGNAL_AFTER_PUBLISH_RENAME"] = str(signal_after)
        return subprocess.run(
            ["/bin/bash", "-c", script],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_release_publication_restores_previous_set_on_signal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for index in range(3):
                (root / f"asset-{index}").write_text(f"old-{index}", encoding="utf-8")
            result = self.run_release_transaction(root, None, signal_after=2)
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(
                [(root / f"asset-{index}").read_text() for index in range(3)],
                [f"old-{index}" for index in range(3)],
            )
            self.assertFalse((root / ".release-set.publish-journal").exists())
            self.assertFalse((root / ".release-set.publish-previous").exists())

    def test_release_publication_restores_complete_previous_set_after_each_rename(self) -> None:
        for failure_after in (1, 2, 3):
            with self.subTest(failure_after=failure_after), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                for index in range(3):
                    (root / f"asset-{index}").write_text(f"old-{index}", encoding="utf-8")
                result = self.run_release_transaction(root, failure_after)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(
                    [(root / f"asset-{index}").read_text() for index in range(3)],
                    [f"old-{index}" for index in range(3)],
                )
                self.assertFalse((root / ".release-set.publish-journal").exists())
                self.assertFalse((root / ".release-set.publish-previous").exists())

    def test_release_publication_commits_complete_new_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for index in range(3):
                (root / f"asset-{index}").write_text(f"old-{index}", encoding="utf-8")
            result = self.run_release_transaction(root, None)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [(root / f"asset-{index}").read_text() for index in range(3)],
                [f"new-{index}" for index in range(3)],
            )
            self.assertFalse((root / ".release-set.publish-journal").exists())
            self.assertFalse((root / ".release-set.publish-previous").exists())

    def test_release_publication_recovers_from_durable_journal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            stage = root / "stage"
            stage.mkdir()
            targets = [root / f"asset-{index}" for index in range(3)]
            sources = [stage / f"new-{index}" for index in range(3)]
            for index in range(3):
                targets[index].write_text(f"old-{index}", encoding="utf-8")
                sources[index].write_text(f"new-{index}", encoding="utf-8")

            publish = f'''set +e
RELEASE_TRANSACTION_ACTIVE=0
source {str(RELEASE_TRANSACTION_SCRIPT)!r}
release_transaction_publish {str(root)!r} release-set \\
  {str(sources[0])!r} {str(targets[0])!r} \\
  {str(sources[1])!r} {str(targets[1])!r} \\
  {str(sources[2])!r} {str(targets[2])!r}
exit 97
'''
            subprocess.run(
                ["/bin/bash", "-c", publish],
                text=True,
                capture_output=True,
                check=False,
                env={**os.environ, "MACREMOTE_TEST_FAIL_AFTER_PUBLISH_RENAME": "2"},
            )
            self.assertTrue((root / ".release-set.publish-journal").exists())

            recover = f'''set -euo pipefail
RELEASE_TRANSACTION_ACTIVE=0
source {str(RELEASE_TRANSACTION_SCRIPT)!r}
targets=({" ".join(repr(str(path)) for path in targets)})
release_transaction_recover_if_needed {str(root)!r} release-set "${{targets[@]}}"
'''
            result = subprocess.run(
                ["/bin/bash", "-c", recover],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [target.read_text() for target in targets],
                [f"old-{index}" for index in range(3)],
            )
            self.assertFalse((root / ".release-set.publish-journal").exists())
            self.assertFalse((root / ".release-set.publish-previous").exists())

    def test_build_script_help_exits_before_swift_or_artifact_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = pathlib.Path(directory)
            script_dir = fixture / "script"
            script_dir.mkdir()
            fixture_script = script_dir / "build_and_run.sh"
            fixture_script.write_bytes(BUILD_SCRIPT.read_bytes())
            fixture_script.chmod(0o755)

            fake_bin = fixture / "fake-bin"
            fake_bin.mkdir()
            swift_marker = fixture / "swift-was-called"
            fake_swift = fake_bin / "swift"
            fake_swift.write_text(
                f"#!/bin/bash\ntouch {swift_marker!s}\nexit 97\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)

            for help_flag in ("-h", "--help"):
                with self.subTest(help_flag=help_flag):
                    result = subprocess.run(
                        ["/bin/bash", str(fixture_script), help_flag],
                        cwd=fixture,
                        text=True,
                        capture_output=True,
                        check=False,
                        env={**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin"},
                    )

                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Show this help without building", result.stdout)
                    self.assertFalse(swift_marker.exists(), f"{help_flag} invoked Swift")
                    self.assertFalse((fixture / "dist").exists(), f"{help_flag} staged an app artifact")


if __name__ == "__main__":
    unittest.main()
