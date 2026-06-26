#!/usr/bin/env python3
"""
Quick eye import script

Usage:
    python import_eyes.py greek_serene_left.png --emotion serene --side left --style greek
    python import_eyes.py *.png --emotion fierce --style roman

This will add eyes to the patch library with proper metadata.
"""

import sys
import argparse
from pathlib import Path
from PIL import Image

# Add parent directory to path to import app modules
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.database import SessionLocal
from app.models.patch import Patch
from app.services.patch_library import PatchLibraryService


def import_eye(
    image_path: Path,
    emotion: str,
    side: str,
    style: str,
    description: str = None
):
    """
    Import a single eye image into the catalog

    Args:
        image_path: Path to eye image file
        emotion: serene, fierce, wise, peaceful, joyful, sorrowful
        side: left, right, both
        style: greek, roman, egyptian, renaissance, custom
        description: Optional custom description
    """

    db = SessionLocal()
    patch_service = PatchLibraryService()

    # Generate name from filename if not provided
    name = image_path.stem.replace('_', ' ').title()

    # Auto-generate description if not provided
    if not description:
        description = f"{style.title()} carved eye, {emotion} expression, {side} side. Suitable for CNC wood carving."

    # Generate tags
    tags = f"{style}, {emotion}, {side}, carved, cnc-ready, wood-carving"

    print(f"\n📸 Importing: {name}")
    print(f"   File: {image_path.name}")
    print(f"   Style: {style}")
    print(f"   Emotion: {emotion}")
    print(f"   Side: {side}")

    try:
        # Create patch record
        patch = Patch(
            name=name,
            description=description,
            source_type="imported",
            category="carved_eye",
            tags=tags,
            width=0,
            height=0,
            user_id=None,
            file_path=""
        )

        db.add(patch)
        db.commit()
        db.refresh(patch)

        # Save image file
        file_path = patch_service.save_patch_from_file(
            patch.id,
            str(image_path),
            create_thumb=True
        )

        # Get and update dimensions
        width, height = patch_service.get_patch_size(patch.id)
        patch.width = width
        patch.height = height
        patch.file_path = file_path
        patch.thumbnail_path = str(patch_service.get_thumbnail_path(patch.id))

        db.commit()

        print(f"✅ Successfully imported!")
        print(f"   ID: {patch.id}")
        print(f"   Size: {width}x{height}px")

        return patch.id

    except Exception as e:
        print(f"❌ Error importing: {e}")
        db.rollback()
        return None

    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(
        description="Import carved eye images into the patch library",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Import a single eye
    python import_eyes.py greek_serene_left.png --emotion serene --side left --style greek

    # Import multiple eyes with same metadata
    python import_eyes.py roman_*.png --emotion fierce --side both --style roman

    # With custom description
    python import_eyes.py statue_eye.png --emotion wise --side right --style roman --description "Emperor Augustus portrait eye"

Emotions: serene, fierce, wise, peaceful, joyful, sorrowful, neutral
Sides: left, right, both
Styles: greek, roman, egyptian, renaissance, baroque, modern, custom
        """
    )

    parser.add_argument(
        'images',
        nargs='+',
        help='Image file(s) to import (supports wildcards)'
    )

    parser.add_argument(
        '--emotion',
        required=True,
        choices=['serene', 'fierce', 'wise', 'peaceful', 'joyful', 'sorrowful', 'neutral'],
        help='Emotional expression of the eye'
    )

    parser.add_argument(
        '--side',
        required=True,
        choices=['left', 'right', 'both'],
        help='Which eye (left or right)'
    )

    parser.add_argument(
        '--style',
        required=True,
        choices=['greek', 'roman', 'egyptian', 'renaissance', 'baroque', 'modern', 'custom'],
        help='Carving style/period'
    )

    parser.add_argument(
        '--description',
        help='Custom description (optional)'
    )

    args = parser.parse_args()

    # Resolve wildcards and get all image files
    image_files = []
    for pattern in args.images:
        path = Path(pattern)
        if '*' in pattern:
            # Wildcard - expand it
            parent = path.parent if path.parent.exists() else Path('.')
            image_files.extend(parent.glob(path.name))
        else:
            # Single file
            if path.exists():
                image_files.append(path)
            else:
                print(f"⚠️  File not found: {pattern}")

    if not image_files:
        print("❌ No image files found!")
        return

    print(f"\n🎨 Importing {len(image_files)} eye image(s) into catalog...")
    print(f"   Style: {args.style}")
    print(f"   Emotion: {args.emotion}")
    print(f"   Side: {args.side}")
    print("="*60)

    imported_count = 0
    for image_path in image_files:
        patch_id = import_eye(
            image_path,
            args.emotion,
            args.side,
            args.style,
            args.description
        )
        if patch_id:
            imported_count += 1

    print("="*60)
    print(f"\n✅ Import complete! {imported_count}/{len(image_files)} eyes added to catalog")
    print(f"\n💡 Access your eye catalog at: http://your-server:3080")
    print(f"   Or via API: GET /patches/?category=carved_eye")


if __name__ == "__main__":
    main()
