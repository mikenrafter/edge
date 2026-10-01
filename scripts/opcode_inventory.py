#!/usr/bin/env python3
"""Print risky command definitions and call sites without contacting a band."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATTERN = re.compile(
    r"dangerousCmds|OpcodeSafety|allowDangerous|Cmd\.(?:forceTrim|reboot|"
    r"powerCycle|loadFirmware|setFfValue)|FOOTGUN\("
)


def inventory():
    paths = list((ROOT / "lib").rglob("*.dart"))
    config = ROOT / ".dart_tool/package_config.json"
    if config.exists():
        from urllib.parse import urlparse, unquote
        for package in json.loads(config.read_text())["packages"]:
            if package["name"] == "openstrap_protocol":
                uri = package["rootUri"]
                base = pathlib.Path(unquote(urlparse(uri).path)) if uri.startswith("file:") else config.parent / uri
                paths.extend((base / "lib").rglob("*.dart"))
    rows = []
    for path in sorted(paths):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if PATTERN.search(line):
                try:
                    name = str(path.relative_to(ROOT))
                except ValueError:
                    name = str(path)
                rows.append({"file": name, "line": number, "source": line.strip()})
    return rows


if __name__ == "__main__":
    print(json.dumps(inventory(), indent=2))
