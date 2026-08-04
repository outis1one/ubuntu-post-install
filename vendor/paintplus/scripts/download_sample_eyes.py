#!/usr/bin/env python3
"""
Download sample classical eye images and import them into the patch catalog.

These are public domain images from Wikimedia Commons of classical sculptures.
Run this script to populate the eye catalog with example eyes.

Usage:
    cd /home/user/EditmaskwithAI
    python scripts/download_sample_eyes.py
"""

import os
import sys
import requests
import sqlite3
from pathlib import Path
from PIL import Image
from io import BytesIO

# Add backend to path
sys.path.insert(0, str(Path(__file__).parent.parent / 'backend'))

# Sample eye images - public domain classical sculpture references
# These URLs point to Wikimedia Commons images of ancient sculptures
SAMPLE_EYES = [
    {
        'name': 'Greek Serene - Left',
        'url': 'https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Head_Hygieia_BM_550.jpg/220px-Head_Hygieia_BM_550.jpg',
        'tags': 'greek,serene,left,marble',
        'category': 'eyes',
        'description': 'Classical Greek style eye from Hygieia statue'
    },
    {
        'name': 'Roman Portrait - Right',
        'url': 'https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Bust_of_Emperor_Philip_the_Arab_-_Hermitage_Museum.jpg/220px-Bust_of_Emperor_Philip_the_Arab_-_Hermitage_Museum.jpg',
        'tags': 'roman,portrait,right,marble',
        'category': 'eyes',
        'description': 'Roman portrait style eye'
    },
    {
        'name': 'Greek Classical - Pair',
        'url': 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/35/Marble_head_of_a_veiled_woman_MET_DT229963.jpg/220px-Marble_head_of_a_veiled_woman_MET_DT229963.jpg',
        'tags': 'greek,classical,pair,marble,veiled',
        'category': 'eyes',
        'description': 'Greek classical style veiled woman'
    },
]

def download_image(url: str) -> bytes:
    """Download image from URL and return bytes"""
    headers = {
        'User-Agent': 'Mozilla/5.0 (compatible; EyeCatalogDownloader/1.0)'
    }
    response = requests.get(url, headers=headers, timeout=30)
    response.raise_for_status()
    return response.content

def create_patch_directory(patch_id: int, data_dir: Path) -> Path:
    """Create directory for patch files"""
    patch_dir = data_dir / 'patches' / str(patch_id)
    patch_dir.mkdir(parents=True, exist_ok=True)
    return patch_dir

def save_patch_and_thumbnail(image_bytes: bytes, patch_dir: Path) -> tuple:
    """Save patch image and create thumbnail"""
    # Open image
    img = Image.open(BytesIO(image_bytes)).convert('RGBA')

    # Save full size
    patch_path = patch_dir / 'patch.png'
    img.save(patch_path, 'PNG')

    # Create thumbnail (max 200x200)
    thumb = img.copy()
    thumb.thumbnail((200, 200), Image.Resampling.LANCZOS)
    thumb_path = patch_dir / 'thumbnail.png'
    thumb.save(thumb_path, 'PNG')

    return patch_path, thumb_path, img.size

def import_eye_to_database(db_path: Path, eye_data: dict, patch_path: str, thumb_path: str, width: int, height: int) -> int:
    """Insert patch record into database"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute('''
        INSERT INTO patches (name, description, source_type, category, tags, file_path, thumbnail_path, width, height)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', (
        eye_data['name'],
        eye_data.get('description', ''),
        'imported',
        eye_data['category'],
        eye_data['tags'],
        str(patch_path),
        str(thumb_path),
        width,
        height
    ))

    patch_id = cursor.lastrowid
    conn.commit()
    conn.close()

    return patch_id

def main():
    # Determine paths - handle both Docker and local environments
    # In Docker: script is at /scripts/, data is at /app/data/
    # Locally: script is at ./scripts/, data is at ./data/
    docker_data_dir = Path('/app/data')
    local_data_dir = Path(__file__).parent.parent / 'data'

    if docker_data_dir.exists():
        data_dir = docker_data_dir
    else:
        data_dir = local_data_dir

    db_path = data_dir / 'ai_photo_edit.db'

    # Check if database exists
    if not db_path.exists():
        print(f"Database not found at {db_path}")
        print("Attempting to initialize database...")
        # Try to import and initialize database
        try:
            sys.path.insert(0, str(Path('/app')))
            sys.path.insert(0, str(Path(__file__).parent.parent / 'backend'))
            from app.database import init_db
            init_db()
            print("Database initialized successfully.")
        except Exception as e:
            print(f"Could not initialize database: {e}")
            print("Please start the backend first to initialize the database.")
            sys.exit(1)

    print(f"Using database: {db_path}")
    print(f"Data directory: {data_dir}")
    print()

    # Check if patches table exists
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='patches'")
    if not cursor.fetchone():
        print("Patches table not found. Creating it...")
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS patches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name VARCHAR NOT NULL,
                description TEXT,
                source_type VARCHAR NOT NULL,
                category VARCHAR,
                tags TEXT,
                file_path VARCHAR,
                thumbnail_path VARCHAR,
                width INTEGER,
                height INTEGER,
                source_project_id INTEGER,
                source_edit_id INTEGER,
                user_id INTEGER,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        conn.commit()
    conn.close()

    successful = 0
    failed = 0

    for eye_data in SAMPLE_EYES:
        print(f"Downloading: {eye_data['name']}...")

        try:
            # Download image
            image_bytes = download_image(eye_data['url'])

            # Get next patch ID
            conn = sqlite3.connect(db_path)
            cursor = conn.cursor()
            cursor.execute("SELECT COALESCE(MAX(id), 0) + 1 FROM patches")
            next_id = cursor.fetchone()[0]
            conn.close()

            # Create directory and save files
            patch_dir = create_patch_directory(next_id, data_dir)
            patch_path, thumb_path, (width, height) = save_patch_and_thumbnail(image_bytes, patch_dir)

            # Import to database
            patch_id = import_eye_to_database(db_path, eye_data, patch_path, thumb_path, width, height)

            print(f"  ✓ Imported as patch #{patch_id} ({width}x{height})")
            successful += 1

        except Exception as e:
            print(f"  ✗ Failed: {e}")
            failed += 1

    print()
    print(f"Done! Imported {successful} eyes, {failed} failed.")
    print()
    print("You can now see the eyes in the Eye Catalog panel in the web UI.")
    print("To add your own eyes:")
    print("  1. Click '+ Add Eye' in the Eye Catalog")
    print("  2. Upload a PNG image (transparency works best)")
    print("  3. Give it a name and tags")

if __name__ == '__main__':
    main()
