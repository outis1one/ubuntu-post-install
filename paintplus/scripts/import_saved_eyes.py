#!/usr/bin/env python3
"""
Import previously saved eye images into the patch library.

This script reads eye images from a directory (along with metadata.json)
and imports them into the patch library database.

Usage:
    python scripts/import_saved_eyes.py /path/to/saved/eyes

This script must be run with backend dependencies available
(e.g., inside the backend container).
"""

import os
import sys
import json
import argparse
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

from PIL import Image
from sqlalchemy.orm import Session
from app.database import SessionLocal, engine, Base
from app.models.patch import Patch
from app.services.patch_library import PatchLibraryService


def import_from_directory(source_dir: Path, db: Session, patch_service: PatchLibraryService) -> int:
    """
    Import eye images from a directory.

    Args:
        source_dir: Directory containing eye images and metadata.json
        db: Database session
        patch_service: PatchLibraryService instance

    Returns:
        Number of successfully imported images
    """
    metadata_path = source_dir / "metadata.json"

    if not metadata_path.exists():
        print(f"Error: metadata.json not found in {source_dir}")
        print("Scanning for PNG files instead...")

        # Fallback: import all PNG files with default metadata
        png_files = list(source_dir.glob("*.png"))
        metadata = []
        for png_file in png_files:
            img = Image.open(png_file)
            metadata.append({
                'filename': png_file.name,
                'name': png_file.stem.replace('_', ' ').title(),
                'description': f'Imported eye image: {png_file.name}',
                'tags': 'eye,imported',
                'width': img.width,
                'height': img.height
            })
    else:
        with open(metadata_path, 'r') as f:
            metadata = json.load(f)

    imported = 0

    for item in metadata:
        try:
            filename = item['filename']
            filepath = source_dir / filename

            if not filepath.exists():
                print(f"  Skipping (file not found): {filename}")
                continue

            name = item['name']
            description = item.get('description', '')
            tags = item.get('tags', 'eye,imported')

            # Check if already exists
            existing = db.query(Patch).filter(Patch.name == name).first()
            if existing:
                print(f"  Skipping (exists): {name}")
                continue

            # Load image
            img = Image.open(filepath)

            # Create database record
            patch = Patch(
                name=name,
                description=description,
                source_type="imported",
                width=img.width,
                height=img.height,
                tags=tags,
                category="eye",
                is_public=True,
                file_path="",
                thumbnail_path=""
            )
            db.add(patch)
            db.flush()

            # Save to patch library
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
            print(f"  Error importing {item.get('filename', 'unknown')}: {e}")

    return imported


def main():
    parser = argparse.ArgumentParser(description='Import saved eye images to patch library')
    parser.add_argument('source_dir', help='Directory containing eye images and metadata.json')
    args = parser.parse_args()

    source_dir = Path(args.source_dir)
    if not source_dir.exists():
        print(f"Error: Directory not found: {source_dir}")
        sys.exit(1)

    print("=" * 60)
    print("Eye Image Importer")
    print("=" * 60)

    # Initialize database
    print("\nInitializing database...")
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()

    # Initialize patch library
    data_dir = os.environ.get("DATA_DIR", str(Path(__file__).parent.parent / "data"))
    patch_service = PatchLibraryService(data_dir)

    print(f"Source directory: {source_dir}")
    print(f"Patch library: {patch_service.patch_library_dir}")

    # Import
    print("\nImporting eyes...")
    imported = import_from_directory(source_dir, db, patch_service)

    print("\n" + "=" * 60)
    print(f"Import Complete! Imported {imported} eyes.")
    print("=" * 60)

    db.close()


if __name__ == "__main__":
    main()
