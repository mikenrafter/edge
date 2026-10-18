#!/usr/bin/env python3
"""Print risky command definitions and call sites without contacting a band."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATTERN = re.compile(
    r"dangerousCmds|OpcodeSafety|allowDangerous|Cmd\.(?:forceTrim|reboot|"
    r"powerCycle|loadFirmware|setFfValue)|FOOTGUN\(|"
    r"static const int (?:forceTrim|rebootStrap|powerCycleStrap|"
    r"startUpdateLoad|loadUpdateData|endUpdateLoad|setFfValue|"
    r"gen5StartUpdateLoad|gen5LoadUpdateData|gen5EndUpdateLoad)\s*="
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
        source = path.read_text()
        block = re.search(r'const Set<int> dangerousCmds\s*=\s*\{([\s\S]*?)\};', source)
        risky_names = set(re.findall(r'Cmd\.([A-Za-z0-9_]+)', block.group(1))) if block else set()
        for number, line in enumerate(source.splitlines(), 1):
            definition = re.search(r'static const int ([A-Za-z0-9_]+)\s*=', line)
            risky_definition = definition and definition.group(1) in risky_names
            if PATTERN.search(line) or risky_definition:
                try:
                    name = str(path.relative_to(ROOT))
                except ValueError:
                    name = str(path)
                row = {"file": name, "line": number, "source": line.strip()}
                if risky_definition:
                    symbol = definition.group(1)
                    if symbol in {'forceTrim', 'setReadPointer'}:
                        category = 'DATA_LOSS'
                    elif symbol in {'rebootStrap', 'powerCycleStrap', 'forgetBonds'}:
                        category = 'LINK_LOSS'
                    elif symbol in {'startUpdateLoad', 'loadUpdateData', 'processUpdateImage'}:
                        category = 'FIRMWARE'
                    else:
                        category = 'PERSISTENT_CONFIG'
                    row.update(symbol=symbol, classification=f'FOOTGUN({category})')
                rows.append(row)
    return rows


if __name__ == "__main__":
    print(json.dumps(inventory(), indent=2))
