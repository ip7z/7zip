"""Integration tests for directory extraction timestamps; uses only Python's stdlib."""
import argparse
import io
import os
from pathlib import Path
import stat
import struct
import subprocess
import tarfile
import tempfile
import time
import unittest
import zipfile

OLD_LOCAL = (2001, 2, 3, 4, 5, 6)
OLD = time.mktime((*OLD_LOCAL, 0, 0, -1))
PAYLOAD = b"File contents and file timestamps must remain unchanged.\n"
DIRS = ("tree", "tree/nested", "tree/nested/empty", "empty")
FILES = ("tree/nested/file.txt", "root.txt")


class DirectoryTimestampTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="7zip-dir-times-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_7zip(self, *args, cwd=None):
        result = subprocess.run([SEVEN_ZIP, *map(str, args)], cwd=cwd,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
        return result.stdout

    def archive(self, kind, implicit=False):
        archive = self.root / ("implicit." if implicit else "explicit.")
        archive = archive.with_suffix("." + kind)
        dirs = () if implicit else DIRS
        if kind == "zip":
            with zipfile.ZipFile(archive, "w") as z:
                for name in dirs:
                    item = zipfile.ZipInfo(name + "/", OLD_LOCAL)
                    item.external_attr = (0o40755 << 16) | 0x10
                    z.writestr(item, b"")
                for name in FILES:
                    item = zipfile.ZipInfo(name, OLD_LOCAL)
                    item.external_attr = (0o100644 << 16) | 0x20
                    z.writestr(item, PAYLOAD)
        elif kind == "tar":
            with tarfile.open(archive, "w") as t:
                for name in dirs:
                    item = tarfile.TarInfo(name)
                    item.type = tarfile.DIRTYPE
                    item.mode = 0o755
                    item.mtime = int(OLD)
                    t.addfile(item)
                for name in FILES:
                    item = tarfile.TarInfo(name)
                    item.mode = 0o644
                    item.mtime = int(OLD)
                    item.size = len(PAYLOAD)
                    t.addfile(item, io.BytesIO(PAYLOAD))
        else:
            source = self.root / "source"
            source.mkdir()
            for name in DIRS:
                (source / name).mkdir(parents=True, exist_ok=True)
            for name in FILES:
                (source / name).write_bytes(PAYLOAD)
                os.utime(source / name, (OLD, OLD))
            for name in reversed(DIRS):
                os.utime(source / name, (OLD, OLD))
            self.run_7zip("a", "-t7z", archive, "tree", "empty", "root.txt", cwd=source)
        return archive

    def extract(self, archive, dest, *switches, command="x"):
        start = time.time()
        self.run_7zip(command, archive, "-y", "-o" + str(dest), *switches)
        return start, time.time()

    def assert_old(self, path):
        self.assertAlmostEqual(path.stat().st_mtime, OLD, delta=2, msg=str(path))

    def assert_current(self, path, window):
        self.assertGreaterEqual(path.stat().st_mtime, window[0] - 2, str(path))
        self.assertLessEqual(path.stat().st_mtime, window[1] + 2, str(path))

    def assert_files(self, dest):
        for name in FILES:
            self.assertEqual((dest / name).read_bytes(), PAYLOAD)
            self.assert_old(dest / name)

    def test_current_nested_empty_and_output_parents(self):
        for kind in ("zip", "tar", "7z"):
            with self.subTest(kind=kind):
                archive = self.archive(kind)
                dest = self.root / kind / "new-parent" / "output"
                window = self.extract(archive, dest, "-sctd")
                for name in DIRS:
                    self.assert_current(dest / name, window)
                for path in (dest, dest.parent, dest.parent.parent):
                    self.assert_current(path, window)
                self.assert_files(dest)

    def test_default_and_explicit_disable_restore_archive_times(self):
        for kind in ("zip", "tar", "7z"):
            archive = self.archive(kind)
            for index, switches in enumerate(((), ("-sctd-",))):
                with self.subTest(kind=kind, switches=switches):
                    dest = self.root / f"{kind}-{index}"
                    self.extract(archive, dest, *switches)
                    for name in DIRS:
                        self.assert_old(dest / name)
                    self.assert_files(dest)

    def test_existing_directories_keep_archive_behavior(self):
        for kind in ("zip", "tar", "7z"):
            with self.subTest(kind=kind):
                archive = self.archive(kind)
                dest = self.root / kind
                (dest / "tree" / "nested").mkdir(parents=True)
                (dest / "unrelated").mkdir()
                os.utime(dest / "unrelated", (OLD, OLD))
                window = self.extract(archive, dest, "-sctd")
                self.assert_old(dest / "tree")
                self.assert_old(dest / "tree/nested")
                self.assert_old(dest / "unrelated")
                self.assert_current(dest / "tree/nested/empty", window)
                self.assert_current(dest / "empty", window)
                self.assert_files(dest)

    def test_implicit_parents_without_directory_entries(self):
        for kind in ("zip", "tar"):
            with self.subTest(kind=kind):
                archive = self.archive(kind, implicit=True)
                dest = self.root / kind
                (dest / "tree").mkdir(parents=True)
                window = self.extract(archive, dest, "-sctd")
                self.assert_current(dest / "tree/nested", window)
                self.assert_files(dest)

    def test_flat_extraction_preserves_file_times(self):
        archive = self.archive("zip")
        dest = self.root / "flat"
        self.extract(archive, dest, "-sctd", command="e")
        for name in ("file.txt", "root.txt"):
            self.assertEqual((dest / name).read_bytes(), PAYLOAD)
            self.assert_old(dest / name)

    def test_test_and_stdout_modes(self):
        archive = self.archive("zip")
        self.run_7zip("t", archive, "-sctd")
        result = self.run_7zip("x", archive, "root.txt", "-so", "-sctd", "-bso0")
        self.assertEqual(result, PAYLOAD)

    def test_multiple_archives_sharing_created_directories(self):
        first = self.archive("zip")
        second = self.root / "second.zip"
        second.write_bytes(first.read_bytes())
        dest = self.root / "multi"
        start = time.time()
        self.run_7zip("x", self.root / "*.zip", "-y", "-sctd", "-o" + str(dest))
        window = (start, time.time())
        for name in DIRS:
            self.assert_current(dest / name, window)
        self.assert_files(dest)

    def test_all_available_file_timestamps_match_default(self):
        archive = self.root / "ntfs-times.zip"
        item = zipfile.ZipInfo("file.txt", OLD_LOCAL)
        ft = int((OLD + 11644473600) * 10000000)
        item.extra = struct.pack("<HHIHHQQQ", 0x000a, 32, 0, 1, 24,
                                 ft, ft - 100000000, ft - 200000000)
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(item, PAYLOAD)
        self.extract(archive, self.root / "default")
        self.extract(archive, self.root / "current", "-sctd")
        a = (self.root / "default/file.txt").stat()
        b = (self.root / "current/file.txt").stat()
        self.assertEqual(a.st_mtime_ns, b.st_mtime_ns)
        self.assertEqual(a.st_atime_ns, b.st_atime_ns)
        self.assertAlmostEqual(a.st_mtime, OLD, delta=2)
        if os.name == "nt":
            self.assertEqual(a.st_birthtime_ns, b.st_birthtime_ns)

    def test_failed_extraction_still_finalizes_created_directories(self):
        archive = self.archive("zip")
        data = bytearray(archive.read_bytes())
        # Corrupt stored file data without changing the central directory CRC.
        offset = data.index(PAYLOAD)
        data[offset] ^= 1
        archive.write_bytes(data)
        dest = self.root / "failed"
        start = time.time()
        result = subprocess.run([SEVEN_ZIP, "x", str(archive), "-y", "-sctd",
                                 "-o" + str(dest)], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 2, result.stdout.decode(errors="replace"))
        self.assertIn(b"CRC Failed", result.stdout)
        for name in DIRS:
            self.assert_current(dest / name, (start, time.time()))
        self.assert_old(dest / FILES[0])
        self.assertEqual((dest / "root.txt").read_bytes(), PAYLOAD)
        self.assert_old(dest / "root.txt")

    def test_output_path_failure_does_not_change_existing_file(self):
        archive = self.archive("zip")
        blocker = self.root / "blocker"
        blocker.write_bytes(PAYLOAD)
        os.utime(blocker, (OLD, OLD))
        result = subprocess.run([SEVEN_ZIP, "x", str(archive), "-y", "-sctd",
                                 "-o" + str(blocker / "output")],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 2, result.stdout.decode(errors="replace"))
        self.assertEqual(blocker.read_bytes(), PAYLOAD)
        self.assert_old(blocker)

    def test_implicit_existing_directories_are_not_restamped(self):
        archive = self.archive("zip", implicit=True)
        dest = self.root / "existing"
        (dest / "tree/nested").mkdir(parents=True)
        for name in FILES:
            (dest / name).write_bytes(PAYLOAD)
            os.utime(dest / name, (OLD, OLD))
        for name in ("tree/nested", "tree"):
            os.utime(dest / name, (OLD, OLD))
        self.extract(archive, dest, "-sctd", "-aos")
        self.assert_old(dest / "tree/nested")
        self.assert_old(dest / "tree")
        self.assert_files(dest)

    @unittest.skipUnless(os.name == "nt", "DOS read-only attributes require Windows")
    def test_readonly_attributes_are_preserved(self):
        archive = self.root / "readonly.zip"
        with zipfile.ZipFile(archive, "w") as z:
            directory = zipfile.ZipInfo("readonly/", OLD_LOCAL)
            directory.create_system = 0
            directory.external_attr = 0x11
            z.writestr(directory, b"")
            item = zipfile.ZipInfo("readonly/file.txt", OLD_LOCAL)
            item.create_system = 0
            item.external_attr = 0x21
            z.writestr(item, PAYLOAD)
        dest = self.root / "readonly-output"
        window = self.extract(archive, dest, "-sctd")
        self.assert_current(dest / "readonly", window)
        self.assert_old(dest / "readonly/file.txt")
        for name in ("readonly", "readonly/file.txt"):
            self.assertTrue((dest / name).stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)

    def test_file_attributes_match_default(self):
        archive = self.archive("zip")
        regular = self.root / "regular"
        current = self.root / "current"
        self.extract(archive, regular)
        self.extract(archive, current, "-sctd")
        for name in (*DIRS, *FILES):
            a, b = (regular / name).stat(), (current / name).stat()
            self.assertEqual(stat.S_IMODE(a.st_mode), stat.S_IMODE(b.st_mode))
            if os.name == "nt":
                self.assertEqual(a.st_file_attributes, b.st_file_attributes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seven-zip", required=True, help="Path to the built 7zz/7za/7z executable")
    args, remaining = parser.parse_known_args()
    SEVEN_ZIP = str(Path(args.seven_zip).resolve())
    unittest.main(argv=[__file__, *remaining])
