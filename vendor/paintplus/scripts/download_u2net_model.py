#!/usr/bin/env python3
"""
Download U2Net model for background removal.

U2Net is a deep learning model for salient object detection,
commonly used for background removal tasks.

Usage:
    python download_u2net_model.py [model_type]

Model types:
    u2net      - Full U2Net model (~176MB, best quality)
    u2netp     - Lightweight U2Net (~4MB, faster, good quality)
    u2net_human_seg - Optimized for human segmentation (~176MB)

Default: u2netp (good balance of quality and speed)
"""

import os
import sys
import urllib.request
from pathlib import Path

# Model URLs (from official U2Net repository releases)
MODEL_URLS = {
    'u2net': {
        'url': 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net.onnx',
        'filename': 'u2net.onnx',
        'size_mb': 176
    },
    'u2netp': {
        'url': 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx',
        'filename': 'u2netp.onnx',
        'size_mb': 4
    },
    'u2net_human_seg': {
        'url': 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net_human_seg.onnx',
        'filename': 'u2net_human_seg.onnx',
        'size_mb': 176
    }
}


def download_with_progress(url: str, dest_path: Path, expected_size_mb: int):
    """Download file with progress indicator."""

    print(f"Downloading from: {url}")
    print(f"Expected size: ~{expected_size_mb}MB")

    def progress_hook(count, block_size, total_size):
        if total_size > 0:
            percent = min(100, count * block_size * 100 // total_size)
            downloaded_mb = count * block_size / (1024 * 1024)
            total_mb = total_size / (1024 * 1024)
            sys.stdout.write(f"\rProgress: {percent}% ({downloaded_mb:.1f}/{total_mb:.1f} MB)")
            sys.stdout.flush()

    try:
        urllib.request.urlretrieve(url, str(dest_path), progress_hook)
        print("\nDownload complete!")
        return True
    except Exception as e:
        print(f"\nDownload failed: {e}")
        return False


def main():
    # Determine model type
    model_type = 'u2netp'  # Default to lightweight model
    if len(sys.argv) > 1:
        model_type = sys.argv[1].lower()

    if model_type not in MODEL_URLS:
        print(f"Unknown model type: {model_type}")
        print(f"Available models: {', '.join(MODEL_URLS.keys())}")
        sys.exit(1)

    model_info = MODEL_URLS[model_type]

    # Determine models directory
    # Check if running in Docker container
    if os.path.exists('/app/data/models'):
        models_dir = Path('/app/data/models')
    else:
        # Local development
        script_dir = Path(__file__).parent
        models_dir = script_dir.parent / 'data' / 'models'

    models_dir.mkdir(parents=True, exist_ok=True)

    dest_path = models_dir / model_info['filename']

    # Check if already downloaded
    if dest_path.exists():
        print(f"Model already exists at: {dest_path}")
        print("Delete the file to re-download.")
        return

    print(f"Downloading U2Net model: {model_type}")
    print(f"Destination: {dest_path}")
    print("")

    success = download_with_progress(
        model_info['url'],
        dest_path,
        model_info['size_mb']
    )

    if success:
        # Create symlink for easier access
        symlink_path = models_dir / 'u2net.onnx'
        if not symlink_path.exists() or symlink_path.is_symlink():
            if symlink_path.is_symlink():
                symlink_path.unlink()
            try:
                symlink_path.symlink_to(dest_path.name)
                print(f"Created symlink: {symlink_path} -> {dest_path.name}")
            except OSError:
                # Symlinks may not work on all systems
                pass

        print(f"\nU2Net model ({model_type}) downloaded successfully!")
        print(f"Location: {dest_path}")
        print("\nYou can now use background removal in the application.")
    else:
        print("\nFailed to download model. Please try again or download manually from:")
        print(f"  {model_info['url']}")
        print(f"  Save to: {dest_path}")
        sys.exit(1)


if __name__ == '__main__':
    main()
