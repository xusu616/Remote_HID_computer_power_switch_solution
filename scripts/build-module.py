#!/usr/bin/env python3
"""Build a Magisk/KernelSU/APatch flashable ZIP from magisk-module/."""

import hashlib
import os
from pathlib import Path
import stat
import zipfile


EXEC_FILES = {
    "META-INF/com/google/android/update-binary",
    "customize.sh",
    "service.sh",
    "uninstall.sh",
    "system/bin/wake-bridge",
    "wake-bridge/setup-hid.sh",
    "wake-bridge/wake.sh",
    "wake-bridge/hid-watchdog.sh",
    "wake-bridge/start-daemon.sh",
    "wake-bridge/stop-daemon.sh",
    "wake-bridge/www/cgi-bin/wake",
    "wake-bridge/www/cgi-bin/status",
}

TEXT_EXTENSIONS = {".sh", ".prop", ".example", ".html", ""}


def parse_module_prop(prop_path: Path) -> dict[str, str]:
    props: dict[str, str] = {}
    for line in prop_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip()
    return props


def build_zip(repo_root: Path) -> Path:
    src_dir = repo_root / "magisk-module"
    props = parse_module_prop(src_dir / "module.prop")
    mod_id = props.get("id", "wake_bridge")
    version = props.get("version", "v1.0.0")

    dist_dir = repo_root / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)
    out_zip = dist_dir / f"{mod_id}-{version}.zip"

    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for file_path in sorted(src_dir.rglob("*")):
            if not file_path.is_file():
                continue
            rel = file_path.relative_to(src_dir).as_posix()
            raw = file_path.read_bytes()
            if file_path.suffix in TEXT_EXTENSIONS:
                raw = raw.replace(b"\r\n", b"\n")

            mode = 0o755 if rel in EXEC_FILES else 0o644
            info = zipfile.ZipInfo(rel)
            info.create_system = 3  # Unix
            info.external_attr = (stat.S_IFREG | mode) << 16
            zf.writestr(info, raw)

    sha256 = hashlib.sha256(out_zip.read_bytes()).hexdigest()
    sha_file = dist_dir / f"{out_zip.name}.sha256"
    sha_file.write_text(f"{sha256}  {out_zip.name}\n", encoding="utf-8")
    print(f"Built: {out_zip}")
    print(f"SHA256: {sha256}")
    return out_zip


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    build_zip(root)
