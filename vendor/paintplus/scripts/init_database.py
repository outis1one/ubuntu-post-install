#!/usr/bin/env python3
"""
Initialize the database before other startup scripts run.

This ensures the database exists and has all required tables
before download_sample_eyes.py tries to use it.
"""

import os
import sys
from pathlib import Path

# Add backend to path - handle both Docker and local environments
# In Docker: backend is at /app/
# Locally: backend is at ./backend/
if Path('/app').exists():
    sys.path.insert(0, '/app')
else:
    sys.path.insert(0, str(Path(__file__).parent.parent / 'backend'))

def main():
    # Import after path setup
    from app.database import engine, Base, init_db
    from app.models import project, user, patch

    print("Initializing database...")

    # Create all tables
    init_db()

    # Verify database was created - check both Docker and local paths
    docker_db_path = Path('/app/data/ai_photo_edit.db')
    local_db_path = Path('./data/ai_photo_edit.db')

    if docker_db_path.exists():
        print(f"✓ Database initialized at: {docker_db_path}")
    elif local_db_path.exists():
        print(f"✓ Database initialized at: {local_db_path}")
    else:
        print("⚠ Database file not found at expected locations, but tables may still be created")

    print("Database initialization complete.")

if __name__ == '__main__':
    main()
