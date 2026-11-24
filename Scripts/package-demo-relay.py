#!/usr/bin/env python3
"""Package only deployable Relay files; never include .env, credentials or admin scripts."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parents[1] / "Relay"
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
output = Path(sys.argv[1]) if len(sys.argv) == 2 else root.parent / f"tmp/demo-access-validation/relay-demo-{stamp}.zip"
output.parent.mkdir(parents=True, exist_ok=True)
files = [root / "index.mjs", root / "package.json", root / "package-lock.json"]
files += sorted((root / "src").rglob("*.js"))
with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        if path.name == ".env" or path.name.endswith((".demo-access.json", ".demo-config.json")):
            raise SystemExit("Unexpected secret file in deployment input.")
        archive.write(path, path.relative_to(root))
receipt = {"artifact": output.name, "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
           "files": len(files), "sourceSHA256": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                                 for p in files if "node_modules" not in p.parts}}
output.with_suffix(".manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps({"artifact": str(output), "files": len(files), "sha256": receipt["sha256"]}))
