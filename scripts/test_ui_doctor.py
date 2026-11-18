import runpy
import unittest
from pathlib import Path

inspect = runpy.run_path(str(Path(__file__).with_name("ui-doctor.py")))["inspect"]

class SnapshotTests(unittest.TestCase):
    def test_reports_only_captured_geometry_and_expected_names(self):
        data = b'''<root><XCUIElementTypeApplication x="0" y="0" width="390" height="844">
          <XCUIElementTypeButton name="safe" visible="true" x="5" y="500" width="50" height="50"/>
          <XCUIElementTypeButton name="private text" visible="true" x="-60" y="0" width="50" height="50"/>
          <XCUIElementTypeKeyboard visible="true" x="0" y="480" width="390" height="364">
            <XCUIElementTypeButton visible="true" x="0" y="500" width="44" height="44"/>
          </XCUIElementTypeKeyboard></XCUIElementTypeApplication></root>'''
        report = inspect(data, ["safe", "destination"])
        self.assertEqual(report["visible_controls"], 2)
        self.assertEqual(report["findings"], [
            ["safe", "cubierto por el teclado"],
            ["Button#2", "visible según WDA pero fuera de pantalla"],
            ["destination", "destino esperado ausente o invisible"]])
        self.assertNotIn("private text", str(report))

    def test_rejects_missing_application(self):
        with self.assertRaises(ValueError):
            inspect(b"<root/>", [])

if __name__ == "__main__":
    unittest.main()
