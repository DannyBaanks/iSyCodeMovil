#!/usr/bin/env python3
"""Inventario estático y revisión de capturas XML de accesibilidad WDA, sin controlar el dispositivo."""
import argparse
import hashlib
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = re.compile(r'\.accessibilityIdentifier\(\s*"([^"\n]+)"\s*\)')
CONTROL = {"Button", "Switch", "TextField", "SecureTextField", "TextView", "Slider", "Link"}


# Conservative lexical check. Report candidates for manual review, including preview code.
EMPTY_BUTTON = re.compile(r"(?m)^[ \t]*Button\s*(?:\(\s*action:\s*\{\s*\}\s*\)|\{\s*\}\s*label:)")

def empty_button_lines(source):
    return [source.count("\n", 0, match.start()) + 1 for match in EMPTY_BUTTON.finditer(source)]


def inventory():
    items = []
    candidates = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        source = path.read_text()
        candidates.extend(dict(source=str(path.relative_to(ROOT)), line=n)
                          for n in empty_button_lines(source))
        for number, line in enumerate(source.splitlines(), 1):
            for name in IDENTIFIER.findall(line):
                items.append(dict(identifier=name, source=str(path.relative_to(ROOT)), line=number))
    return dict(controls=items, empty_button_candidates=candidates)


def bounds(node):
    try:
        x, y, w, h = (float(node.get(key, "")) for key in ("x", "y", "width", "height"))
    except ValueError:
        return None
    if all(map(math.isfinite, (x, y, w, h))) and w > 0 and h > 0:
        return x, y, x + w, y + h
    return None


def kind(node):
    return node.get("type", node.tag).removeprefix("XCUIElementType")


def inspect(data, expected):
    root = ET.fromstring(data)
    app = next((item for item in root.iter() if kind(item) == "Application"), None)
    if app is None or bounds(app) is None:
        raise ValueError("La captura requiere un elemento Application con geometría válida.")
    viewport = bounds(app)
    findings = []
    keyboards = [bounds(item) for item in app.iter() if kind(item) == "Keyboard"
                 and item.get("visible") == "true" and bounds(item)]
    keyboard_nodes = {id(child) for item in app.iter() if kind(item) == "Keyboard"
                      for child in item.iter()}
    visible = set()
    controls = 0
    for node in app.iter():
        if node.get("visible") != "true" or id(node) in keyboard_nodes:
            continue
        identifier = node.get("name") or ""
        if identifier:
            visible.add(identifier)
        if kind(node) not in CONTROL:
            continue
        controls += 1
        # WDA names may contain user content. Report only identifiers requested by the operator.
        ref = identifier if identifier in expected else f"{kind(node)}#{controls}"
        box = bounds(node)
        if not node.get("label") and not identifier:
            findings.append([ref, "sin nombre accesible"])
        if box is None:
            findings.append([ref, "sin geometría válida"])
            continue
        x, y, right, bottom = box
        if right <= viewport[0] or bottom <= viewport[1] or x >= viewport[2] or y >= viewport[3]:
            findings.append([ref, "visible según WDA pero fuera de pantalla"])
        if any(kx <= x and ky <= y and kr >= right and kb >= bottom for kx, ky, kr, kb in keyboards):
            findings.append([ref, "cubierto por el teclado"])
    for missing in sorted(set(expected) - visible):
        findings.append([missing, "destino esperado ausente o invisible"])
    return dict(evidence="captura WDA", sha256=hashlib.sha256(data).hexdigest(),
                visible_controls=controls, findings=findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, help="XML WDA capturado externamente")
    parser.add_argument("--expect", action="append", default=[], help="identificador visible esperado")
    args = parser.parse_args()
    if args.expect and not args.snapshot:
        parser.error("--expect requiere --snapshot")
    if args.snapshot:
        try:
            result = inspect(args.snapshot.read_bytes(), args.expect)
        except (OSError, ValueError, ET.ParseError) as error:
            parser.error(str(error))
    else:
        result = dict(evidence="estático: declaraciones de identificadores literales y plantillas",
                      **inventory())
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return int(bool(result.get("findings")))


if __name__ == "__main__":
    raise SystemExit(main())
