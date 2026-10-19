import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "airplay-probe-sstate-cache.py"
SPEC = importlib.util.spec_from_file_location("sstate_cache", SCRIPT)
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)


class SstateCacheTests(unittest.TestCase):
    def setUp(self):
        self.original_limit = CACHE.LIMIT
        self.addCleanup(setattr, CACHE, "LIMIT", self.original_limit)

    def test_stage_keeps_complete_priority_groups_within_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            preflight = firmware / "build/airplay-probe-preflight"
            source = preflight / "yocto/sstate-cache"
            source.mkdir(parents=True)
            marker = preflight / "probe-artifacts/bitbake-server-stop.txt"
            marker.parent.mkdir()
            marker.write_text("stop_status=0\n")
            CACHE.LIMIT = 80
            names = [
                ("universal/aa/bb/sstate:rust-native:x.tar.zst", 30),
                ("aa/bb/sstate:clang-native:x.tar.zst", 30),
                ("aa/bb/sstate:unrelated:x.tar.zst", 30),
            ]
            for name, size in names:
                archive = source / name
                archive.parent.mkdir(parents=True, exist_ok=True)
                archive.write_bytes(b"a" * size)
                Path(str(archive) + ".siginfo").write_bytes(b"s" * 10)
            result = CACHE.stage(firmware)
            self.assertTrue(result)
            staged = preflight / "sstate-cache-input"
            manifest = json.loads((staged / "manifest.json").read_text())
            self.assertEqual(manifest["total_bytes"], 80)
            included = {item["name"] for item in manifest["files"]}
            self.assertIn("universal/aa/bb/sstate:rust-native:x.tar.zst", included)
            self.assertIn("universal/aa/bb/sstate:rust-native:x.tar.zst.siginfo", included)
            self.assertNotIn("aa/bb/sstate:unrelated:x.tar.zst", included)

    def test_manifest_rejects_traversal_and_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / "cache"
            cache.mkdir()
            (cache / "manifest.json").write_text(json.dumps({
                "schema": CACHE.SCHEMA,
                "total_bytes": 1,
                "files": [{"name": "../../outside.tar.zst", "size": 1}],
            }))
            with self.assertRaises(SystemExit):
                CACHE.validate(cache)

            (cache / "manifest.json").write_text(json.dumps({
                "schema": CACHE.SCHEMA, "total_bytes": 0, "files": ["bad-entry"],
            }))
            with self.assertRaises(SystemExit):
                CACHE.validate(cache)

            (cache / "manifest.json").write_text(json.dumps({
                "schema": CACHE.SCHEMA, "total_bytes": 0, "files": [{"name": 3}],
            }))
            with self.assertRaises(SystemExit):
                CACHE.validate(cache)

            outside = Path(temp) / "outside"
            outside.mkdir()
            payload = outside / "sstate:rust-native:x.tar.zst"
            payload.write_bytes(b"x")
            (outside / "sstate:rust-native:x.tar.zst.siginfo").write_bytes(b"s")
            (cache / "aa").symlink_to(outside, target_is_directory=True)
            (cache / "manifest.json").write_text(json.dumps({
                "schema": CACHE.SCHEMA,
                "total_bytes": 2,
                "files": [{"name": "aa/bb/sstate:rust-native:x.tar.zst", "size": 1}],
            }))
            with self.assertRaises(SystemExit):
                CACHE.validate(cache)

    def test_corrupt_cache_falls_back_without_creating_sstate(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            root = firmware / "build/airplay-probe-preflight"
            cache = root / "sstate-cache-input"
            cache.mkdir(parents=True)
            (cache / "manifest.json").write_text(json.dumps({
                "schema": CACHE.SCHEMA, "files": ["bad"], "total_bytes": 0,
            }))
            CACHE.restore(firmware)
            self.assertFalse((root / "yocto/sstate-cache").exists())

            archive = cache / "universal/aa/bb/sstate:rust-native:x.tar.zst"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"archive")
            (cache / "manifest.json").write_text(json.dumps({
                "schema": CACHE.SCHEMA,
                "files": [{"name": "universal/aa/bb/sstate:rust-native:x.tar.zst", "size": 7}],
                "total_bytes": 7,
            }))
            CACHE.restore(firmware)
            self.assertFalse((root / "yocto/sstate-cache").exists())

    def test_stage_ignores_incomplete_and_unrecognized_files(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            source = firmware / "build/airplay-probe-preflight/yocto/sstate-cache"
            source.mkdir(parents=True)
            marker = source.parents[1] / "probe-artifacts/bitbake-server-stop.txt"
            marker.parent.mkdir()
            marker.write_text("stop_status=0\n")
            path = source / "aa/bb/sstate:cargo-native:x.tar.zst"
            path.parent.mkdir(parents=True)
            path.write_bytes(b"archive")
            (source / "partial.tmp").write_bytes(b"partial")
            self.assertFalse(CACHE.stage(firmware))
            manifest = json.loads((source.parents[1] / "sstate-cache-input/manifest.json").read_text())
            self.assertEqual(manifest["files"], [])
            self.assertEqual(manifest["total_bytes"], 0)

    def test_stage_then_restore_round_trips_nested_zstd_pair(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            root = firmware / "build/airplay-probe-preflight"
            source = root / "yocto/sstate-cache"
            archive = source / "ubuntu-22.04/aa/bb/sstate:rust-native:x.tar.zst"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"zstd archive")
            Path(str(archive) + ".siginfo").write_bytes(b"signature")
            marker = root / "probe-artifacts/bitbake-server-stop.txt"
            marker.parent.mkdir()
            marker.write_text("stop_status=0\n")

            self.assertTrue(CACHE.stage(firmware))
            shutil.rmtree(source)
            CACHE.restore(firmware)
            restored = source / "ubuntu-22.04/aa/bb/sstate:rust-native:x.tar.zst"
            self.assertEqual(restored.read_bytes(), b"zstd archive")
            self.assertEqual(Path(str(restored) + ".siginfo").read_bytes(), b"signature")

    def test_stage_skips_without_confirmed_server_stop(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            root = firmware / "build/airplay-probe-preflight"
            source = root / "yocto/sstate-cache"
            source.mkdir(parents=True)
            archive = source / "aa/bb/sstate:rust-native:x.tar.zst"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"archive")
            Path(str(archive) + ".siginfo").write_bytes(b"sig")
            self.assertFalse(CACHE.stage(firmware))

    def test_stage_rejects_sstate_root_and_staging_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            root = firmware / "build/airplay-probe-preflight"
            (root / "yocto").mkdir(parents=True)
            external = firmware / "external"
            external.mkdir()
            sentinel = external / "keep.txt"
            sentinel.write_text("keep")
            (root / "sstate-cache-input").symlink_to(root / "yocto", target_is_directory=True)
            marker = root / "probe-artifacts/bitbake-server-stop.txt"
            marker.parent.mkdir()
            marker.write_text("stop_status=0\n")
            with self.assertRaises(SystemExit):
                CACHE.stage(firmware)
            self.assertEqual(sentinel.read_text(), "keep")

            (root / "sstate-cache-input").unlink()
            (root / "yocto/sstate-cache").symlink_to(external, target_is_directory=True)
            with self.assertRaises(SystemExit):
                CACHE.stage(firmware)

    def test_restore_rejects_symlinked_shard_without_writing_outside(self):
        with tempfile.TemporaryDirectory() as temp:
            firmware = Path(temp)
            root = firmware / "build/airplay-probe-preflight"
            source = root / "yocto/sstate-cache"
            archive = source / "aa/bb/sstate:rust-native:x.tar.zst"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"archive")
            Path(str(archive) + ".siginfo").write_bytes(b"sig")
            marker = root / "probe-artifacts/bitbake-server-stop.txt"
            marker.parent.mkdir()
            marker.write_text("stop_status=0\n")
            self.assertTrue(CACHE.stage(firmware))
            shutil.rmtree(source)
            outside = firmware / "outside"
            outside.mkdir()
            (root / "yocto/sstate-cache").mkdir()
            (root / "yocto/sstate-cache/aa").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(SystemExit):
                CACHE.restore(firmware)
            self.assertEqual(list(outside.iterdir()), [])

    def test_rotation_keeps_two_generations_across_owned_scopes(self):
        current = "airplay-sstate-v1-current-current"
        entries = [
            {"id": 1, "key": current, "created_at": "2026-10-19T02:00:00Z", "size_in_bytes": 4 * 1024**3},
            {"id": 2, "key": "airplay-sstate-v1-prior-new", "created_at": "2026-10-19T06:00:00Z", "size_in_bytes": 4 * 1024**3},
            {"id": 3, "key": "airplay-sstate-v1-prior-mid", "created_at": "2026-10-19T05:00:00Z", "size_in_bytes": 1},
            {"id": 4, "key": "airplay-sstate-v1-prior-old", "created_at": "2026-10-19T01:00:00Z", "size_in_bytes": 1},
            {"id": 5, "key": "other-cache", "created_at": "2026-10-19T00:00:00Z", "size_in_bytes": 1},
        ]
        deleted = []

        class Response:
            status = 204

            def __init__(self, body=b""):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return self.body

        def fake_open(request, timeout=30):
            if request.get_method() == "DELETE":
                deleted.append(request.full_url.rsplit("/", 1)[-1])
                return Response()
            return Response(json.dumps({"actions_caches": entries}).encode())

        with patch.object(CACHE, "cache_keys", return_value=("airplay-sstate-v1-scope-", current)):
            with patch.object(CACHE.urllib.request, "urlopen", side_effect=fake_open):
                with patch.dict("os.environ", {"GITHUB_TOKEN": "test-token", "GITHUB_REPOSITORY": "keedle/catplay-firmware"}):
                    CACHE.rotate(Path("/unused"))
        self.assertEqual(deleted, ["3", "4"])

    def test_rotation_never_deletes_without_confirmed_current_save(self):
        deleted = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return json.dumps({"actions_caches": [
                    {"id": 1, "key": "airplay-sstate-v1-scope-old", "created_at": "2026-10-19T03:00:00Z", "size_in_bytes": 1},
                ]}).encode()

        def fake_open(request, timeout=30):
            if request.get_method() == "DELETE":
                deleted.append(request.full_url)
            return Response()

        with patch.object(CACHE, "cache_keys", return_value=("airplay-sstate-v1-scope-", "airplay-sstate-v1-scope-current")):
            with patch.object(CACHE.urllib.request, "urlopen", side_effect=fake_open):
                with patch.dict("os.environ", {"GITHUB_TOKEN": "test-token", "GITHUB_REPOSITORY": "keedle/catplay-firmware"}):
                    CACHE.rotate(Path("/unused"))
        self.assertEqual(deleted, [])

    def test_rotation_makes_no_api_call_for_another_repository(self):
        with patch.object(CACHE, "cache_keys", return_value=("airplay-sstate-v1-scope-", "airplay-sstate-v1-scope-current")):
            with patch.object(CACHE.urllib.request, "urlopen") as open_url:
                with patch.dict("os.environ", {"GITHUB_TOKEN": "test-token", "GITHUB_REPOSITORY": "someone/else"}):
                    CACHE.rotate(Path("/unused"))
        open_url.assert_not_called()


if __name__ == "__main__":
    unittest.main()
