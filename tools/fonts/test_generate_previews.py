"""Checks font addition/removal/renaming without changing project resources."""
import contextlib
import io
from pathlib import Path
import tempfile
import textwrap
import unittest
from unittest.mock import patch

import yaml
import generate_previews as generator


class FontPreviewMaintenanceTest(unittest.TestCase):
    def test_add_delete_and_rename(self):
        project = Path(__file__).resolve().parents[2]
        # An independent fixture stays available even if built-in fonts change.
        source = (project / "assets/fonts/reading_quote/LongCang-Regular.ttf").read_bytes()
        with tempfile.TemporaryDirectory(dir=project / "build", prefix="font-preview-test-") as directory:
            root = Path(directory)
            (root / "lib/platform/channels").mkdir(parents=True)
            (root / "assets/fonts/preset").mkdir(parents=True)
            originals = root / "assets/fonts/preset/example.ttf"
            originals.write_bytes(source)
            output = root / "assets/fonts/preview"
            catalog = root / "lib/platform/channels/preset_fonts.dart"

            def configure(names):
                catalog.write_text("const families = {\n" + "".join(
                    f"'{family}': (name: '{name}', file: 'example.ttf', bold: null),\n"
                    for family, name in names.items()) + "};\n", "utf-8")
                fonts = [{"family": family, "fonts": [
                    {"asset": "assets/fonts/preset/example.ttf", "weight": weight}
                    for weight in ([400, 700] if family.endswith("two") else [400])
                ]} for family in names]
                (root / "pubspec.yaml").write_text(
                    "flutter:\n  fonts:\n" + textwrap.indent(yaml.safe_dump(fonts, sort_keys=False), "    "), "utf-8")

            def run(check=False):
                with patch.object(generator, "ROOT", root), patch.object(generator, "OUTPUT", output):
                    with contextlib.redirect_stdout(io.StringIO()):
                        generator.generate(check)

            configure({"gt-preset-one": "阅读一"})
            run()
            run(check=True)
            self.assertEqual(len(list(output.glob("*.ttf"))), 1)
            configure({"gt-preset-one": "阅读一", "gt-preset-two": "阅读二"})
            run()
            run(check=True)
            self.assertEqual(len(list(output.glob("*.ttf"))), 3)
            registered = yaml.safe_load((root / "pubspec.yaml").read_text("utf-8"))["flutter"]["fonts"]
            paired = next(font for font in registered if font["family"] == "gt-preview-two")
            self.assertEqual([face["weight"] for face in paired["fonts"]], [400, 700])
            configure({"gt-preset-two": "阅读二"})
            run()
            run(check=True)
            self.assertEqual(len(list(output.glob("*.ttf"))), 2)
            self.assertFalse((output / "gt-preview-one-400.ttf").exists())
            configure({"gt-preset-two": "阅读改名"})
            with self.assertRaisesRegex(ValueError, "outdated"):
                run(check=True)
            run()
            run(check=True)
            self.assertIn("阅读改名（内置）", (root / "lib/platform/channels/preset_font_previews.dart").read_text("utf-8"))
            self.assertEqual(originals.read_bytes(), source)


if __name__ == "__main__":
    unittest.main()
