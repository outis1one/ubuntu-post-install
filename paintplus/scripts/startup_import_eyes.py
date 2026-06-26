#!/usr/bin/env python3
"""
Startup script to import classic eyes into the patch library.
This should be run once when the backend starts, or manually.

Usage:
    python scripts/startup_import_eyes.py

This script:
1. Converts PPM files to PNG (if needed)
2. Imports all classic eyes into the patch library database
"""

import os
import sys
import json
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

try:
    from PIL import Image
    from sqlalchemy.orm import Session
    from app.database import SessionLocal, engine, Base
    from app.models.patch import Patch
    from app.services.patch_library import PatchLibraryService
except ImportError as e:
    print(f"Error: Required modules not available: {e}")
    print("Run this script inside the backend container.")
    sys.exit(1)


def convert_ppm_to_png(ppm_dir: Path) -> int:
    """Convert all PPM files to PNG in the given directory."""
    converted = 0
    for ppm_file in ppm_dir.glob("*.ppm"):
        png_file = ppm_file.with_suffix('.png')
        if not png_file.exists():
            try:
                img = Image.open(ppm_file)
                img.save(png_file, 'PNG')
                converted += 1
                print(f"  Converted: {ppm_file.name} -> {png_file.name}")
            except Exception as e:
                print(f"  Error converting {ppm_file.name}: {e}")
    return converted


def import_eyes(source_dir: Path, db: Session, patch_service: PatchLibraryService) -> int:
    """Import eye images from the given directory."""
    metadata_path = source_dir / "metadata.json"

    if not metadata_path.exists():
        print(f"  No metadata.json found in {source_dir}")
        return 0

    with open(metadata_path, 'r') as f:
        metadata = json.load(f)

    imported = 0

    for item in metadata:
        try:
            # Try PNG first, then PPM
            filename = item.get('filename', item.get('ppm_filename', '')).replace('.ppm', '.png')
            filepath = source_dir / filename

            if not filepath.exists():
                # Try PPM
                filepath = source_dir / item.get('ppm_filename', filename.replace('.png', '.ppm'))

            if not filepath.exists():
                continue

            name = item['name']

            # Check if already exists
            existing = db.query(Patch).filter(Patch.name == name).first()
            if existing:
                continue  # Silent skip for duplicates on startup

            # Load and convert if PPM
            img = Image.open(filepath).convert('RGBA')

            # Create database record
            patch = Patch(
                name=name,
                description=item.get('description', ''),
                source_type="imported",
                width=img.width,
                height=img.height,
                tags=item.get('tags', 'eye,classic'),
                category="eye",
                is_public=True,
                file_path="",
                thumbnail_path=""
            )
            db.add(patch)
            db.flush()

            # Save to patch library as PNG
            patch_path = patch_service.get_patch_path(patch.id)
            img.save(patch_path, 'PNG')

            # Create thumbnail
            thumb_path = patch_service.get_thumbnail_path(patch.id)
            patch_service.create_thumbnail(patch_path, thumb_path)

            # Update paths
            patch.file_path = f"patch_library/{patch.id}.png"
            patch.thumbnail_path = f"patch_library/{patch.id}_thumb.png"

            db.commit()
            imported += 1
            print(f"  Imported: {name} (ID: {patch.id})")

        except Exception as e:
            db.rollback()
            print(f"  Error: {e}")

    return imported


def main():
    print("=" * 60)
    print("Classic Eyes Startup Import")
    print("=" * 60)

    # Find the classic eyes directory
    data_dir = Path(os.environ.get("DATA_DIR", "/app/data"))
    if not data_dir.exists():
        data_dir = Path(__file__).parent.parent / "data"

    ppm_dir = data_dir / "classic_eyes_ppm"

    if not ppm_dir.exists():
        print(f"\nNo classic eyes found at: {ppm_dir}")
        print("Run generate_classic_eyes_ppm.py first.")
        return

    # Initialize database
    print("\nInitializing database...")
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()

    # Initialize patch library
    patch_service = PatchLibraryService(str(data_dir))

    # Convert PPM to PNG
    print("\nConverting PPM to PNG (if needed)...")
    converted = convert_ppm_to_png(ppm_dir)
    if converted > 0:
        print(f"  Converted {converted} files")
    else:
        print("  All files already converted")

    # Import eyes
    print("\nImporting classic eyes...")
    imported = import_eyes(ppm_dir, db, patch_service)

    # Count existing
    total = db.query(Patch).filter(Patch.category == "eye").count()

    print("\n" + "=" * 60)
    print(f"Import Complete!")
    print(f"  Newly imported: {imported}")
    print(f"  Total eye patches in library: {total}")
    print("=" * 60)

    db.close()


if __name__ == "__main__":
    main()
