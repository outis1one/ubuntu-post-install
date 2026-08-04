# Classic Eyes Scripts

This directory contains scripts for generating and importing classic eye images into the AI Photo Edit patch library.

## Overview

The scripts generate a variety of classic eye styles that can be used as reusable patches for photo editing:

- **Realistic eyes** - Detailed eyes with gradient irises and realistic highlights
- **Anime eyes** - Large, expressive eyes in anime style with prominent highlights
- **Cartoon eyes** - Simple, bold cartoon-style eyes

Each style is available in multiple iris colors: blue, green, brown, hazel, grey, and amber.

## Scripts

### 1. `generate_classic_eyes_ppm.py`

Generates classic eye images using only the Python standard library (no dependencies required).

```bash
python scripts/generate_classic_eyes_ppm.py
```

This creates PPM format images in `data/classic_eyes_ppm/`. PPM is a simple image format that can be converted to PNG later.

### 2. `download_classic_eyes.py`

Full-featured script that generates eyes and imports them directly into the patch library. Requires PIL/Pillow.

```bash
# Run inside the backend container
docker exec -it ai-photo-edit-backend python /app/../scripts/download_classic_eyes.py

# Or with the API running
python scripts/download_classic_eyes.py --api --base-url http://localhost:8101

# Or save to a directory for later import
python scripts/download_classic_eyes.py --output-dir ./my_eyes
```

### 3. `startup_import_eyes.py`

Converts PPM files to PNG and imports them into the patch library. Run this inside the backend container.

```bash
docker exec -it ai-photo-edit-backend python /app/../scripts/startup_import_eyes.py
```

### 4. `import_saved_eyes.py`

Import previously saved eye images from a directory.

```bash
python scripts/import_saved_eyes.py /path/to/saved/eyes
```

## Quick Start

1. **Generate the eye images** (no dependencies needed):
   ```bash
   python scripts/generate_classic_eyes_ppm.py
   ```

2. **Start the application**:
   ```bash
   docker compose up -d
   ```

3. **Import the eyes**:
   ```bash
   docker exec -it ai-photo-edit-backend python /scripts/startup_import_eyes.py
   ```

4. **Verify in the app**: Open the patch library in the UI to see the imported classic eyes.

## Generated Eyes

| Style     | Colors Available                          | Size   |
|-----------|-------------------------------------------|--------|
| Realistic | Blue, Green, Brown, Hazel, Grey, Amber    | 200x200|
| Anime     | Blue, Green, Brown, Hazel, Grey, Amber    | 200x200|
| Cartoon   | Blue, Green, Brown, Hazel, Grey, Amber    | 200x200|

Total: 18 unique eye variants

## Extending

To add more eye styles or colors, edit the `generate_classic_eyes_ppm.py` or `download_classic_eyes.py` scripts:

```python
# Add new color
colors["purple"] = (128, 0, 128)

# Add new style in create_classic_eye() function
elif style == "fantasy":
    # Your custom eye drawing code
    pass
```

## File Formats

- **PPM**: Portable Pixmap format - simple, universal, generated without dependencies
- **PNG**: Preferred format for the patch library - converted from PPM using PIL

## License

The generated eye images are created programmatically and are free to use without restrictions.
