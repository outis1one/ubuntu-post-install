#!/usr/bin/env python3
"""
Download Real-ESRGAN NCNN Vulkan binary.

This gives you fast AI upscaling on ANY GPU (Intel/AMD/NVIDIA integrated or discrete,
Apple Metal) without needing CUDA or Python AI packages.

Usage:
    docker exec -it ai-photo-edit python /scripts/download_realesrgan.py
    # or locally:
    python scripts/download_realesrgan.py
"""

import os
import sys
import platform
import zipfile
import urllib.request
import stat
from pathlib import Path

DEST_DIR = Path("/app/data/models/realesrgan")
VERSION = "v0.2.5.0"

PLATFORM_MAP = {
    "linux":  f"realesrgan-ncnn-vulkan-{VERSION}-ubuntu.zip",
    "darwin": f"realesrgan-ncnn-vulkan-{VERSION}-macos.zip",
    "win32":  f"realesrgan-ncnn-vulkan-{VERSION}-windows.zip",
    "windows": f"realesrgan-ncnn-vulkan-{VERSION}-windows.zip",
}

BASE_URL = f"https://github.com/xinntao/Real-ESRGAN/releases/download/{VERSION}"


def main():
    plat = sys.platform.lower()
    if plat not in PLATFORM_MAP:
        print(f"Unknown platform: {plat}")
        sys.exit(1)

    filename = PLATFORM_MAP[plat]
    url = f"{BASE_URL}/{filename}"
    zip_path = DEST_DIR / filename

    DEST_DIR.mkdir(parents=True, exist_ok=True)

    binary_name = "realesrgan-ncnn-vulkan.exe" if "win" in plat else "realesrgan-ncnn-vulkan"
    binary_path = DEST_DIR / binary_name

    if binary_path.exists():
        print(f"Already installed: {binary_path}")
        print("Delete it and re-run to reinstall.")
        return

    print(f"Downloading Real-ESRGAN NCNN Vulkan {VERSION} for {plat}...")
    print(f"URL: {url}")

    def progress(count, block_size, total_size):
        if total_size > 0 and count % 100 == 0:
            pct = min(100, count * block_size * 100 // total_size)
            mb = count * block_size / 1024 / 1024
            total_mb = total_size / 1024 / 1024
            print(f"  {pct}% ({mb:.1f}/{total_mb:.1f} MB)", end="\r")

    urllib.request.urlretrieve(url, zip_path, progress)
    print(f"\nDownloaded to {zip_path}")

    print("Extracting...")
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(DEST_DIR)

    # The zip extracts into a subdirectory — find the binary
    found = list(DEST_DIR.rglob(binary_name))
    if not found:
        print(f"ERROR: Could not find {binary_name} in extracted files.")
        sys.exit(1)

    extracted = found[0]
    if extracted != binary_path:
        extracted.rename(binary_path)

    # Make executable on unix
    if "win" not in plat:
        binary_path.chmod(binary_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    # Clean up zip
    zip_path.unlink(missing_ok=True)

    print(f"\nInstalled: {binary_path}")
    print("\nTest it:")
    print(f"  {binary_path} --help")
    print("\nThe upscaler will auto-detect this binary next time you use Upscale in PaintPlus.")
    print("Restart the backend container to clear the capability cache:")
    print("  docker-compose restart backend")


if __name__ == "__main__":
    main()
