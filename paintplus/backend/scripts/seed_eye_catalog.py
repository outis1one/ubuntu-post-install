"""
Seed the patch library with classical carved eyes from public domain sources

This script helps pre-populate the eye catalog with examples from:
- Greek statues (Metropolitan Museum, Louvre)
- Roman sculptures (Smithsonian, British Museum)
- Renaissance carvings
- Ancient Egyptian carved eyes

All images should be public domain (CC0, Public Domain Mark)
"""

import asyncio
import httpx
from pathlib import Path
from PIL import Image
from io import BytesIO

# Public domain eye examples to seed the catalog
# These are examples - you would add actual URLs from museum APIs
CLASSICAL_EYES = [
    {
        "name": "Greek Statue - Serene Left Eye",
        "description": "Classical Greek marble carving, convex eyeball, defined upper lid, deep socket. Perfect for serene expressions.",
        "category": "carved_eye",
        "tags": "greek, serene, left, marble, classical, convex, deep-socket",
        "style": "greek_classical",
        "emotion": "serene",
        "side": "left",
        "source_url": "https://images.metmuseum.org/...",  # Example
        "source": "Metropolitan Museum of Art - Public Domain"
    },
    {
        "name": "Roman Sculpture - Fierce Right Eye",
        "description": "Roman marble, prominent brow ridge, intense gaze, sharp eyelid definition.",
        "category": "carved_eye",
        "tags": "roman, fierce, right, marble, intense, sharp-detail",
        "style": "roman_classical",
        "emotion": "fierce",
        "side": "right",
        "source_url": "https://...",
        "source": "Smithsonian - CC0"
    },
    {
        "name": "Greek Kouros - Peaceful Left Eye",
        "description": "Archaic Greek style, almond-shaped, subtle carving, peaceful expression.",
        "category": "carved_eye",
        "tags": "greek, peaceful, left, archaic, almond-shaped, subtle",
        "style": "greek_archaic",
        "emotion": "peaceful",
        "side": "left",
        "source_url": "https://...",
        "source": "Getty Museum - Public Domain"
    },
    {
        "name": "Roman Portrait - Wise Right Eye",
        "description": "Late Roman period, detailed eyelids, slight downward gaze, wisdom and age.",
        "category": "carved_eye",
        "tags": "roman, wise, right, portrait, detailed, aged",
        "style": "roman_portrait",
        "emotion": "wise",
        "side": "right",
        "source_url": "https://...",
        "source": "British Museum - CC0"
    },
]

async def download_image(url: str) -> bytes:
    """Download image from URL"""
    async with httpx.AsyncClient() as client:
        response = await client.get(url)
        response.raise_for_status()
        return response.content

async def crop_eye_from_statue(image_bytes: bytes, crop_box: tuple) -> bytes:
    """
    Crop just the eye from a full statue photo

    Args:
        image_bytes: Full statue image
        crop_box: (left, top, right, bottom) coordinates

    Returns:
        Cropped eye image bytes
    """
    img = Image.open(BytesIO(image_bytes))
    eye = img.crop(crop_box)

    # Save as PNG
    buffer = BytesIO()
    eye.save(buffer, format='PNG')
    return buffer.getvalue()

async def seed_eye_catalog():
    """
    Seed the patch library with classical carved eyes

    NOTE: This is a template. You need to:
    1. Get actual public domain image URLs
    2. Manually crop the eyes (or provide crop coordinates)
    3. Run this to populate the catalog
    """

    from app.database import SessionLocal
    from app.models.patch import Patch
    from app.services.patch_library import PatchLibraryService

    db = SessionLocal()
    patch_service = PatchLibraryService()

    print("Seeding eye catalog with classical carved eyes...")

    for eye_data in CLASSICAL_EYES:
        print(f"\nAdding: {eye_data['name']}")

        # Create patch record
        patch = Patch(
            name=eye_data['name'],
            description=eye_data['description'],
            source_type="imported",
            category=eye_data['category'],
            tags=eye_data['tags'],
            width=0,  # Will be set after image save
            height=0,
            user_id=None,
            file_path=""
        )

        db.add(patch)
        db.commit()
        db.refresh(patch)

        # Download and save image
        # NOTE: You need to manually download/crop these first
        # This is just the structure

        try:
            # image_bytes = await download_image(eye_data['source_url'])
            # cropped_eye = await crop_eye_from_statue(image_bytes, crop_box)

            # For now, you would manually place images in:
            # ./seed_data/eyes/greek_serene_left.png
            # ./seed_data/eyes/roman_fierce_right.png
            # etc.

            seed_image_path = Path(__file__).parent / "seed_data" / "eyes" / f"{eye_data['style']}_{eye_data['emotion']}_{eye_data['side']}.png"

            if seed_image_path.exists():
                file_path = patch_service.save_patch_from_file(
                    patch.id,
                    str(seed_image_path),
                    create_thumb=True
                )

                # Get dimensions
                width, height = patch_service.get_patch_size(patch.id)
                patch.width = width
                patch.height = height
                patch.file_path = file_path
                patch.thumbnail_path = str(patch_service.get_thumbnail_path(patch.id))

                db.commit()
                print(f"✅ Added {eye_data['name']}")
            else:
                print(f"⚠️  Image not found: {seed_image_path}")
                print(f"   Please download and crop eye from: {eye_data['source']}")

        except Exception as e:
            print(f"❌ Error adding {eye_data['name']}: {e}")
            db.rollback()

    db.close()
    print("\n✅ Eye catalog seeding complete!")

if __name__ == "__main__":
    asyncio.run(seed_eye_catalog())
