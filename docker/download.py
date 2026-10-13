"""Download pinned binaries; no download utilities are shipped in the image."""

import hashlib
import http.client
from pathlib import Path
import sys
import urllib.request
import zipfile


XRAY_VERSION = "v26.3.27"
RATHOLE_VERSION = "v0.5.0"
ASSETS = {
    "amd64": (
        ("XTLS/Xray-core", XRAY_VERSION, "Xray-linux-64.zip", "xray",
         "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"),
        ("rathole-org/rathole", RATHOLE_VERSION,
         "rathole-x86_64-unknown-linux-gnu.zip", "rathole",
         "3e7d0d0f365120cd3cd351d147d1a12ee960c8068b464d4dd533a3821873b80e"),
    ),
    "arm64": (
        ("XTLS/Xray-core", XRAY_VERSION, "Xray-linux-arm64-v8a.zip", "xray",
         "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"),
        ("rathole-org/rathole", RATHOLE_VERSION,
         "rathole-aarch64-unknown-linux-musl.zip", "rathole",
         "fa4a6fc63d86f8f1faa7c103a845e4715ce79a048455c0eec897b27237576564"),
    ),
}


def download(arch, output):
    if arch not in ASSETS:
        raise ValueError(f"Unsupported architecture: {arch}")
    output.mkdir(parents=True, exist_ok=True)
    for repo, version, asset, binary, checksum in ASSETS[arch]:
        url = f"https://github.com/{repo}/releases/download/{version}/{asset}"
        archive = output / asset
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=120) as source:
                    archive.write_bytes(source.read())
                break
            except (OSError, http.client.IncompleteRead):
                if attempt == 2:
                    raise
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise ValueError(f"SHA-256 mismatch: {asset}")
        with zipfile.ZipFile(archive) as package:
            (output / binary).write_bytes(package.read(binary))
        (output / binary).chmod(0o755)
        archive.unlink()


if __name__ == "__main__":
    download(sys.argv[1], Path(sys.argv[2]))
