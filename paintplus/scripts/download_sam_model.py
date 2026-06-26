#!/usr/bin/env python3
"""
Download SAM (Segment Anything Model) for local inference.

This script downloads the SAM model checkpoint to a persistent directory
so it survives container rebuilds.

Models available:
- sam_vit_b: ~375MB (default, good balance of speed/quality)
- sam_vit_l: ~1.2GB (better quality, slower)
- sam_vit_h: ~2.5GB (best quality, slowest)

Usage:
    python scripts/download_sam_model.py [model_type]

    model_type: vit_b (default), vit_l, or vit_h
"""

import os
import sys
import urllib.request
from pathlib import Path

# Model URLs from Meta's official releases
SAM_MODELS = {
    'vit_b': {
        'url': 'https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth',
        'filename': 'sam_vit_b_01ec64.pth',
        'size': '375MB'
    },
    'vit_l': {
        'url': 'https://dl.fbaipublicfiles.com/segment_anything/sam_vit_l_0b3195.pth',
        'filename': 'sam_vit_l_0b3195.pth',
        'size': '1.2GB'
    },
    'vit_h': {
        'url': 'https://dl.fbaipublicfiles.com/segment_anything/sam_vit_h_4b8939.pth',
        'filename': 'sam_vit_h_4b8939.pth',
        'size': '2.5GB'
    }
}

def create_symlink(symlink_path: Path, target_name: str):
    """Best-effort convenience symlink. Never raises — a missing/stale
    symlink is harmless (callers also check the real filename directly),
    but data/models/ is often root-owned from a prior Docker run, which
    makes unlink/symlink_to fail with PermissionError for other users."""
    try:
        if symlink_path.exists() or symlink_path.is_symlink():
            symlink_path.unlink()
        symlink_path.symlink_to(target_name)
        print(f"Symlink created: {symlink_path} -> {target_name}")
    except OSError as e:
        print(f"(skipping symlink: {e})")


def download_with_progress(url: str, dest_path: Path):
    """Download file with progress indicator"""
    print(f"Downloading to: {dest_path}")

    def progress_hook(count, block_size, total_size):
        percent = int(count * block_size * 100 / total_size)
        mb_done = count * block_size / (1024 * 1024)
        mb_total = total_size / (1024 * 1024)
        sys.stdout.write(f"\r  Progress: {percent}% ({mb_done:.1f}/{mb_total:.1f} MB)")
        sys.stdout.flush()

    urllib.request.urlretrieve(url, dest_path, progress_hook)
    print("\n  Download complete!")

def main():
    # Determine model type
    model_type = sys.argv[1] if len(sys.argv) > 1 else 'vit_b'

    if model_type not in SAM_MODELS:
        print(f"Unknown model type: {model_type}")
        print(f"Available: {', '.join(SAM_MODELS.keys())}")
        sys.exit(1)

    model_info = SAM_MODELS[model_type]

    # Determine models directory
    # Check if running in Docker (mounted volume) or locally
    models_dir = Path('/app/data/models')
    if not models_dir.exists():
        models_dir = Path(__file__).parent.parent / 'data' / 'models'

    models_dir.mkdir(parents=True, exist_ok=True)

    dest_path = models_dir / model_info['filename']

    print("=" * 60)
    print("SAM Model Downloader")
    print("=" * 60)
    print(f"Model: SAM {model_type.upper()}")
    print(f"Size: {model_info['size']}")
    print(f"License: Apache 2.0 (commercial use OK)")
    print("=" * 60)

    # Check if already downloaded
    if dest_path.exists():
        print(f"\nModel already exists at: {dest_path}")
        print("To re-download, delete the file first.")

        create_symlink(models_dir / 'sam_model.pth', dest_path.name)
        return

    print(f"\nDownloading SAM {model_type.upper()} ({model_info['size']})...")
    print("This is a one-time download. The model will persist across rebuilds.")
    print()

    try:
        download_with_progress(model_info['url'], dest_path)

        symlink_path = models_dir / 'sam_model.pth'
        create_symlink(symlink_path, dest_path.name)

        print()
        print("=" * 60)
        print("SUCCESS!")
        print(f"Model saved to: {dest_path}")
        print("=" * 60)

    except Exception as e:
        print(f"\nError downloading model: {e}")
        if dest_path.exists():
            dest_path.unlink()
        sys.exit(1)

if __name__ == '__main__':
    main()
