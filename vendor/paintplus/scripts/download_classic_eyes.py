#!/usr/bin/env python3
"""
Download and import classic eye images into the patch library.

This script downloads open-source/public domain eye images and imports them
into the AI Photo Edit patch library for use as reusable eye patches.

Sources:
- OpenGameArt.org (CC0/Public Domain game assets)
- Generated stylized eyes using PIL
- Public domain vintage illustrations

Usage:
    # Run inside the backend container or with backend dependencies:
    python scripts/download_classic_eyes.py

    # Or run via API when app is running:
    python scripts/download_classic_eyes.py --api --base-url http://localhost:8101
"""

import os
import sys
import io
import json
import argparse
from pathlib import Path
from datetime import datetime

# Try to import dependencies
try:
    from PIL import Image, ImageDraw, ImageFilter
    HAS_PIL = True
except ImportError:
    HAS_PIL = False
    print("Warning: PIL not available. Install with: pip install Pillow")

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

try:
    from sqlalchemy.orm import Session
    from app.database import SessionLocal, engine, Base
    from app.models.patch import Patch
    from app.services.patch_library import PatchLibraryService
    HAS_BACKEND = True
except ImportError:
    HAS_BACKEND = False
    print("Warning: Backend modules not available. Use --api mode or run inside backend container.")


# Public domain eye image sources (CC0/Public Domain)
CLASSIC_EYE_URLS = [
    # OpenGameArt style eyes - these are placeholder URLs
    # In production, you would use actual public domain image URLs
]

# We'll generate classic stylized eyes instead since downloading from external
# sources can be unreliable. These are better quality and guaranteed available.


def create_classic_eye(
    size: tuple = (200, 200),
    iris_color: tuple = (70, 130, 180),  # Steel blue
    pupil_size_ratio: float = 0.3,
    iris_size_ratio: float = 0.7,
    style: str = "realistic"
) -> Image.Image:
    """
    Generate a classic stylized eye image.

    Args:
        size: Output image size (width, height)
        iris_color: RGB color for the iris
        pupil_size_ratio: Ratio of pupil to iris
        iris_size_ratio: Ratio of iris to eye
        style: "realistic", "anime", "cartoon", "vintage"

    Returns:
        PIL Image with transparent background
    """
    img = Image.new('RGBA', size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    center_x, center_y = size[0] // 2, size[1] // 2
    eye_radius = min(size) // 2 - 5
    iris_radius = int(eye_radius * iris_size_ratio)
    pupil_radius = int(iris_radius * pupil_size_ratio)

    if style == "realistic":
        # White of the eye (sclera) with slight pink tint
        sclera_color = (250, 245, 240, 255)
        draw.ellipse(
            [center_x - eye_radius, center_y - eye_radius,
             center_x + eye_radius, center_y + eye_radius],
            fill=sclera_color,
            outline=(180, 160, 150, 255),
            width=2
        )

        # Iris with gradient effect
        for i in range(iris_radius, 0, -2):
            ratio = i / iris_radius
            color = (
                int(iris_color[0] * ratio + 40 * (1 - ratio)),
                int(iris_color[1] * ratio + 40 * (1 - ratio)),
                int(iris_color[2] * ratio + 40 * (1 - ratio)),
                255
            )
            draw.ellipse(
                [center_x - i, center_y - i, center_x + i, center_y + i],
                fill=color
            )

        # Pupil
        draw.ellipse(
            [center_x - pupil_radius, center_y - pupil_radius,
             center_x + pupil_radius, center_y + pupil_radius],
            fill=(10, 10, 10, 255)
        )

        # Highlight/reflection
        highlight_x = center_x - pupil_radius // 2
        highlight_y = center_y - pupil_radius // 2
        highlight_radius = pupil_radius // 3
        draw.ellipse(
            [highlight_x - highlight_radius, highlight_y - highlight_radius,
             highlight_x + highlight_radius, highlight_y + highlight_radius],
            fill=(255, 255, 255, 200)
        )

    elif style == "anime":
        # Large iris, small pupil, big highlight - anime style
        iris_radius = int(eye_radius * 0.85)

        # Sclera
        draw.ellipse(
            [center_x - eye_radius, center_y - eye_radius,
             center_x + eye_radius, center_y + eye_radius],
            fill=(255, 255, 255, 255),
            outline=(0, 0, 0, 255),
            width=3
        )

        # Large iris
        draw.ellipse(
            [center_x - iris_radius, center_y - iris_radius,
             center_x + iris_radius, center_y + iris_radius],
            fill=iris_color + (255,)
        )

        # Pupil
        pupil_radius = int(iris_radius * 0.25)
        draw.ellipse(
            [center_x - pupil_radius, center_y - pupil_radius,
             center_x + pupil_radius, center_y + pupil_radius],
            fill=(0, 0, 0, 255)
        )

        # Large anime-style highlight
        hl_x, hl_y = center_x - iris_radius // 3, center_y - iris_radius // 3
        hl_r = iris_radius // 3
        draw.ellipse(
            [hl_x - hl_r, hl_y - hl_r, hl_x + hl_r, hl_y + hl_r],
            fill=(255, 255, 255, 255)
        )

        # Secondary smaller highlight
        hl2_x, hl2_y = center_x + iris_radius // 4, center_y + iris_radius // 4
        hl2_r = iris_radius // 6
        draw.ellipse(
            [hl2_x - hl2_r, hl2_y - hl2_r, hl2_x + hl2_r, hl2_y + hl2_r],
            fill=(255, 255, 255, 200)
        )

    elif style == "cartoon":
        # Simple cartoon eye
        # Sclera
        draw.ellipse(
            [center_x - eye_radius, center_y - eye_radius,
             center_x + eye_radius, center_y + eye_radius],
            fill=(255, 255, 255, 255),
            outline=(0, 0, 0, 255),
            width=4
        )

        # Simple colored iris
        draw.ellipse(
            [center_x - iris_radius, center_y - iris_radius,
             center_x + iris_radius, center_y + iris_radius],
            fill=iris_color + (255,),
            outline=(0, 0, 0, 255),
            width=2
        )

        # Pupil
        draw.ellipse(
            [center_x - pupil_radius, center_y - pupil_radius,
             center_x + pupil_radius, center_y + pupil_radius],
            fill=(0, 0, 0, 255)
        )

        # Highlight
        hl_r = pupil_radius // 2
        draw.ellipse(
            [center_x - pupil_radius - hl_r, center_y - pupil_radius - hl_r,
             center_x - pupil_radius + hl_r, center_y - pupil_radius + hl_r],
            fill=(255, 255, 255, 255)
        )

    elif style == "vintage":
        # Vintage engraving style eye
        # Multiple concentric circles for hatching effect
        draw.ellipse(
            [center_x - eye_radius, center_y - eye_radius,
             center_x + eye_radius, center_y + eye_radius],
            fill=(245, 235, 220, 255),
            outline=(80, 60, 40, 255),
            width=2
        )

        # Iris with hatching-like rings
        for i in range(iris_radius, pupil_radius, -4):
            ratio = (i - pupil_radius) / (iris_radius - pupil_radius)
            alpha = int(150 + 100 * ratio)
            draw.ellipse(
                [center_x - i, center_y - i, center_x + i, center_y + i],
                outline=(60 + int(iris_color[0] * 0.3),
                        50 + int(iris_color[1] * 0.3),
                        40 + int(iris_color[2] * 0.3), alpha),
                width=1
            )

        # Dark pupil
        draw.ellipse(
            [center_x - pupil_radius, center_y - pupil_radius,
             center_x + pupil_radius, center_y + pupil_radius],
            fill=(20, 15, 10, 255)
        )

    # Apply slight blur for more natural look
    if style in ["realistic", "vintage"]:
        img = img.filter(ImageFilter.GaussianBlur(radius=0.5))

    return img


def generate_eye_variants() -> list:
    """
    Generate a set of classic eye variants with different colors and styles.

    Returns:
        List of (name, description, tags, image) tuples
    """
    variants = []

    # Eye colors
    colors = {
        "blue": (70, 130, 180),
        "green": (60, 140, 90),
        "brown": (139, 90, 43),
        "hazel": (150, 120, 70),
        "grey": (120, 130, 140),
        "amber": (180, 130, 50),
        "violet": (138, 43, 226),
        "black": (30, 30, 35),
    }

    # Styles
    styles = ["realistic", "anime", "cartoon", "vintage"]

    # Sizes
    sizes = {
        "small": (100, 100),
        "medium": (200, 200),
        "large": (300, 300),
    }

    # Generate all combinations for medium size, main styles
    for style in styles:
        for color_name, color_rgb in colors.items():
            size = sizes["medium"]
            img = create_classic_eye(
                size=size,
                iris_color=color_rgb,
                style=style
            )

            name = f"Classic {style.title()} Eye - {color_name.title()}"
            description = f"A {style} style eye with {color_name} iris color"
            tags = f"eye,classic,{style},{color_name},medium"

            variants.append((name, description, tags, img))

    # Add some extra size variants for most popular combinations
    popular = [
        ("blue", "realistic"),
        ("brown", "realistic"),
        ("green", "realistic"),
        ("blue", "anime"),
        ("green", "anime"),
    ]

    for color_name, style in popular:
        color_rgb = colors[color_name]
        for size_name, size in sizes.items():
            if size_name == "medium":
                continue  # Already generated

            img = create_classic_eye(
                size=size,
                iris_color=color_rgb,
                style=style
            )

            name = f"Classic {style.title()} Eye - {color_name.title()} ({size_name})"
            description = f"A {size_name} {style} style eye with {color_name} iris"
            tags = f"eye,classic,{style},{color_name},{size_name}"

            variants.append((name, description, tags, img))

    return variants


def download_external_eyes() -> list:
    """
    Download eye images from external public domain sources.

    Returns:
        List of (name, description, tags, image) tuples
    """
    if not HAS_REQUESTS or not HAS_PIL:
        print("  Skipping external downloads (missing dependencies)")
        return []

    results = []

    # OpenGameArt and other CC0 sources
    # These are example URLs - in production, curate actual public domain images
    external_sources = [
        {
            "url": "https://opengameart.org/sites/default/files/eye_0.png",
            "name": "OpenGameArt Eye Sprite",
            "description": "Pixel art style eye from OpenGameArt (CC0)",
            "tags": "eye,pixel,game,sprite,public_domain"
        },
    ]

    for source in external_sources:
        try:
            response = requests.get(source["url"], timeout=10)
            if response.status_code == 200:
                img = Image.open(io.BytesIO(response.content)).convert('RGBA')
                results.append((
                    source["name"],
                    source["description"],
                    source["tags"],
                    img
                ))
                print(f"  Downloaded: {source['name']}")
            else:
                print(f"  Failed to download {source['name']}: HTTP {response.status_code}")
        except Exception as e:
            print(f"  Error downloading {source['name']}: {e}")

    return results


def import_eyes_to_library(eyes: list, db: Session, patch_service: PatchLibraryService):
    """
    Import eye images into the patch library database.

    Args:
        eyes: List of (name, description, tags, image) tuples
        db: Database session
        patch_service: PatchLibraryService instance
    """
    imported_count = 0

    for name, description, tags, img in eyes:
        try:
            # Check if patch with same name already exists
            existing = db.query(Patch).filter(Patch.name == name).first()
            if existing:
                print(f"  Skipping (exists): {name}")
                continue

            # Create database record first to get ID
            patch = Patch(
                name=name,
                description=description,
                source_type="imported",
                width=img.width,
                height=img.height,
                tags=tags,
                category="eye",
                is_public=True,
                file_path="",  # Will update after saving
                thumbnail_path=""
            )
            db.add(patch)
            db.flush()  # Get the ID

            # Save image file
            patch_path = patch_service.get_patch_path(patch.id)
            img.save(patch_path, 'PNG')

            # Create thumbnail
            thumb_path = patch_service.get_thumbnail_path(patch.id)
            patch_service.create_thumbnail(patch_path, thumb_path)

            # Update paths in database
            patch.file_path = f"patch_library/{patch.id}.png"
            patch.thumbnail_path = f"patch_library/{patch.id}_thumb.png"

            db.commit()
            imported_count += 1
            print(f"  Imported: {name} (ID: {patch.id})")

        except Exception as e:
            db.rollback()
            print(f"  Error importing {name}: {e}")

    return imported_count


def import_via_api(eyes: list, base_url: str) -> int:
    """
    Import eyes via the REST API.

    Args:
        eyes: List of (name, description, tags, image) tuples
        base_url: Base URL of the API (e.g., http://localhost:8101)

    Returns:
        Number of successfully imported eyes
    """
    if not HAS_REQUESTS:
        print("Error: requests library required for API mode")
        return 0

    imported = 0
    for name, description, tags, img in eyes:
        try:
            # Convert image to bytes
            img_buffer = io.BytesIO()
            img.save(img_buffer, format='PNG')
            img_buffer.seek(0)

            # Upload via API
            files = {'file': (f'{name}.png', img_buffer, 'image/png')}
            data = {
                'name': name,
                'description': description,
                'tags': tags,
                'category': 'eye',
                'source_type': 'imported'
            }

            response = requests.post(
                f"{base_url}/patches/",
                files=files,
                data=data,
                timeout=30
            )

            if response.status_code in [200, 201]:
                patch_id = response.json().get('id', 'unknown')
                print(f"  Imported: {name} (ID: {patch_id})")
                imported += 1
            elif response.status_code == 409:
                print(f"  Skipping (exists): {name}")
            else:
                print(f"  Failed to import {name}: HTTP {response.status_code}")

        except Exception as e:
            print(f"  Error importing {name}: {e}")

    return imported


def save_eyes_to_files(eyes: list, output_dir: Path) -> int:
    """
    Save generated eyes as PNG files for manual import later.

    Args:
        eyes: List of (name, description, tags, image) tuples
        output_dir: Directory to save images

    Returns:
        Number of saved files
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    saved = 0

    # Create a metadata file
    metadata = []

    for name, description, tags, img in eyes:
        try:
            # Create safe filename
            safe_name = name.replace(' ', '_').replace('-', '_').lower()
            safe_name = ''.join(c for c in safe_name if c.isalnum() or c == '_')
            filename = f"{safe_name}.png"

            filepath = output_dir / filename
            img.save(filepath, 'PNG')

            metadata.append({
                'filename': filename,
                'name': name,
                'description': description,
                'tags': tags,
                'width': img.width,
                'height': img.height
            })

            saved += 1

        except Exception as e:
            print(f"  Error saving {name}: {e}")

    # Write metadata JSON
    metadata_path = output_dir / "metadata.json"
    with open(metadata_path, 'w') as f:
        json.dump(metadata, f, indent=2)

    print(f"  Saved metadata to: {metadata_path}")

    return saved


def main():
    """Main function to download and import classic eyes."""
    parser = argparse.ArgumentParser(description='Download and import classic eye images')
    parser.add_argument('--api', action='store_true', help='Use API mode to import')
    parser.add_argument('--base-url', default='http://localhost:8101', help='API base URL')
    parser.add_argument('--output-dir', help='Save images to directory instead of importing')
    parser.add_argument('--skip-external', action='store_true', help='Skip downloading external images')
    args = parser.parse_args()

    print("=" * 60)
    print("Classic Eye Importer for AI Photo Edit")
    print("=" * 60)

    if not HAS_PIL:
        print("\nError: PIL/Pillow is required. Install with: pip install Pillow")
        print("Or run this script inside the backend container.")
        sys.exit(1)

    all_eyes = []

    # Generate stylized eyes
    print("\n[1/3] Generating classic stylized eyes...")
    generated_eyes = generate_eye_variants()
    print(f"  Generated {len(generated_eyes)} eye variants")
    all_eyes.extend(generated_eyes)

    # Download external public domain eyes
    if not args.skip_external:
        print("\n[2/3] Downloading external public domain eyes...")
        external_eyes = download_external_eyes()
        print(f"  Downloaded {len(external_eyes)} external eyes")
        all_eyes.extend(external_eyes)
    else:
        print("\n[2/3] Skipping external downloads (--skip-external)")

    # Determine import method
    print(f"\n[3/3] Processing {len(all_eyes)} eyes...")

    if args.output_dir:
        # Save to files
        output_dir = Path(args.output_dir)
        print(f"  Saving to directory: {output_dir}")
        saved = save_eyes_to_files(all_eyes, output_dir)
        print(f"  Saved {saved} eye images to {output_dir}")

    elif args.api:
        # Import via API
        print(f"  Using API mode: {args.base_url}")
        imported = import_via_api(all_eyes, args.base_url)
        print(f"\n  Successfully imported: {imported}")
        print(f"  Skipped/Failed: {len(all_eyes) - imported}")

    elif HAS_BACKEND:
        # Direct database import
        print("  Using direct database import...")
        Base.metadata.create_all(bind=engine)
        db = SessionLocal()

        data_dir = os.environ.get("DATA_DIR", str(Path(__file__).parent.parent / "data"))
        patch_service = PatchLibraryService(data_dir)
        print(f"  Patch library dir: {patch_service.patch_library_dir}")

        imported = import_eyes_to_library(all_eyes, db, patch_service)

        # Summary
        print("\n" + "=" * 60)
        print("Import Complete!")
        print(f"  Total eyes processed: {len(all_eyes)}")
        print(f"  Successfully imported: {imported}")
        print(f"  Skipped (duplicates): {len(all_eyes) - imported}")
        print("=" * 60)

        # Show sample of imported eyes
        print("\nSample of imported eyes:")
        samples = db.query(Patch).filter(Patch.category == "eye").limit(5).all()
        for p in samples:
            print(f"  - {p.name} ({p.width}x{p.height}) [ID: {p.id}]")

        db.close()

    else:
        # Fallback: save to files
        output_dir = Path(__file__).parent.parent / "data" / "classic_eyes_import"
        print(f"  Backend not available. Saving to: {output_dir}")
        saved = save_eyes_to_files(all_eyes, output_dir)
        print(f"\n  Saved {saved} eye images")
        print(f"\n  To import later, run inside backend container:")
        print(f"    python scripts/import_saved_eyes.py {output_dir}")


if __name__ == "__main__":
    main()
