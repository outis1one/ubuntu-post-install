# Eye Catalog Import Scripts

Tools for populating your carved eye catalog with public domain examples.

---

## Quick Start

### 1. Download Classical Eyes

Follow the guide: `/docs/PUBLIC_DOMAIN_EYE_SOURCES.md`

**Best sources:**
- Metropolitan Museum (CC0)
- Smithsonian Open Access
- Getty Museum Open Content

**Download 10-20 high-res images** of carved eyes from classical sculptures.

---

### 2. Crop the Eyes

Use any image editor (Photoshop, GIMP, Preview, etc.):

1. Open statue photo
2. Zoom in on eye
3. Crop just the eye (include eyelids, socket, tear duct)
4. Save as PNG with descriptive name:
   - `greek_serene_left.png`
   - `roman_fierce_right.png`
   - `egyptian_wise_left.png`

---

### 3. Import to Catalog

**Easy way (one at a time):**
```bash
cd backend/scripts

# Import a Greek serene eye
python import_eyes.py greek_serene_left.png \
  --emotion serene \
  --side left \
  --style greek

# Import a Roman fierce eye
python import_eyes.py roman_fierce_right.png \
  --emotion fierce \
  --side right \
  --style roman
```

**Batch import:**
```bash
# Import all Greek eyes at once
python import_eyes.py greek_*.png \
  --emotion serene \
  --side both \
  --style greek

# Import all Roman eyes
python import_eyes.py roman_*.png \
  --emotion fierce \
  --side both \
  --style roman
```

---

## Available Options

### Emotions
- `serene` - Peaceful, calm (most classical Greek)
- `fierce` - Intense, powerful (Hellenistic, Alexander)
- `wise` - Aged, experienced (Roman senators)
- `peaceful` - Gentle, kind (Archaic Greek)
- `joyful` - Happy, smiling (rare in classical)
- `sorrowful` - Sad, mourning (some Hellenistic)
- `neutral` - Default, no strong emotion

### Styles
- `greek` - Classical Greek (450-400 BCE)
- `roman` - Roman Republican/Imperial
- `egyptian` - Ancient Egyptian carved eyes
- `renaissance` - Renaissance sculpture
- `baroque` - Baroque period
- `modern` - Contemporary carving
- `custom` - Your own style

### Sides
- `left` - Left eye
- `right` - Right eye
- `both` - Can be used for either (symmetric)

---

## Example Workflow

### Build a Complete Catalog

```bash
# 1. Download eyes from Met Museum
# (See PUBLIC_DOMAIN_EYE_SOURCES.md)

# 2. Crop and save them:
#    greek_serene_left.png
#    greek_serene_right.png
#    roman_fierce_left.png
#    roman_fierce_right.png
#    etc.

# 3. Import them all:

python import_eyes.py greek_serene_left.png --emotion serene --side left --style greek
python import_eyes.py greek_serene_right.png --emotion serene --side right --style greek
python import_eyes.py roman_fierce_left.png --emotion fierce --side left --style roman
python import_eyes.py roman_fierce_right.png --emotion fierce --side right --style roman

# Or batch:
python import_eyes.py greek_*.png --emotion serene --side both --style greek
python import_eyes.py roman_*.png --emotion fierce --side both --style roman
```

---

## Recommended Starting Collection

### 10 Essential Eyes

1. **Greek Serene Left** (peaceful carvings)
2. **Greek Serene Right**
3. **Greek Archaic Left** (stylized, simple)
4. **Greek Archaic Right**
5. **Roman Fierce Left** (powerful portraits)
6. **Roman Fierce Right**
7. **Roman Wise Left** (aged, realistic)
8. **Roman Wise Right**
9. **Egyptian Stylized Left** (distinctive style)
10. **Egyptian Stylized Right**

This gives you 5 styles/emotions to start!

---

## Check Your Catalog

### Via API

```bash
# List all eyes in catalog
curl http://localhost:8101/patches/?category=carved_eye

# Filter by emotion
curl http://localhost:8101/patches/?category=carved_eye&tags=serene

# Filter by style
curl http://localhost:8101/patches/?tags=greek
```

### Via Web Interface

Go to: `http://your-server:3080`

Navigate to patch library to browse your eyes visually.

---

## Advanced: Seed Script

For batch importing from the `seed_data/eyes/` directory:

```bash
# 1. Place all cropped eyes in:
mkdir -p seed_data/eyes/
# Copy your eye images there

# 2. Edit seed_eye_catalog.py to add metadata

# 3. Run:
python seed_eye_catalog.py
```

This auto-imports all eyes in `seed_data/eyes/` with pre-configured metadata.

---

## Tips

1. **High resolution:** Use images 1000px+ for best results
2. **Clean crops:** Include some surrounding area, not just the eyeball
3. **Consistent naming:** Use descriptive filenames
4. **Test first:** Import 2-3 eyes to test the workflow
5. **Build gradually:** Start with 10 eyes, expand as needed

---

## Troubleshooting

**"File not found":**
- Make sure you're in `backend/scripts/` directory
- Use full path or relative path to image

**"Database connection error":**
- Make sure backend is running: `docker compose up backend`
- Check database exists: `ls -la ../../data/`

**"Import failed":**
- Check image format (PNG, JPG supported)
- Verify file isn't corrupted
- Check file permissions

---

## Next Steps

After importing eyes:

1. **Test them:** Apply to a colored photo via API
2. **Refine:** Add more variations as needed
3. **Build library:** Aim for 20-30 eyes covering all emotions
4. **Share:** Your best eyes can be exported and shared

**Your catalog of master sculptor's eyes is ready to use!**
