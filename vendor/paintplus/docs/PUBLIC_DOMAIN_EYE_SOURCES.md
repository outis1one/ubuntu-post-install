# Public Domain Carved Eye Sources

Where to find high-quality images of carved eyes from classical sculptures (all public domain).

---

## Best Museums with Public Domain Images

### 1. Metropolitan Museum of Art (CC0 Public Domain)

**Website:** https://www.metmuseum.org/art/collection

**Search tips:**
- Search: "greek statue marble head"
- Search: "roman portrait bust"
- Filter: "Public Domain" only
- Download: Click "Download" for high-resolution

**Great examples:**
- Greek Kouros heads (Archaic period)
- Roman portrait busts
- Hellenistic marble sculptures

**Direct collections:**
- Greek & Roman Art: https://www.metmuseum.org/art/collection/search#!?department=13
- Filter by "Images" → "Public Domain"

---

### 2. Smithsonian Open Access (CC0)

**Website:** https://www.si.edu/openaccess

**Features:**
- 3 million+ images
- All CC0 (no copyright restrictions)
- High-resolution downloads

**Search:**
- "roman marble head"
- "greek sculpture eyes"
- "classical portrait bust"

**API available:** https://api.si.edu/openaccess/api/v1.0/

---

### 3. Getty Museum (Open Content)

**Website:** https://www.getty.edu/art/collection/

**Search tips:**
- Filter: "Open Content Program"
- Greek and Roman antiquities
- High-resolution IIIF images

**Great for:**
- Archaic Greek sculptures
- Classical period heads
- Detailed close-ups

---

### 4. Rijksmuseum (Public Domain)

**Website:** https://www.rijksmuseum.nl/en/rijksstudio

**Features:**
- Rijksstudio (free download tool)
- High-resolution images
- Classical sculpture collection

---

### 5. British Museum (CC BY-NC-SA 4.0)

**Website:** https://www.britishmuseum.org/collection

**Note:** Some restrictions, but many images free for non-commercial use

**Great for:**
- Egyptian carved eyes
- Greek marble heads
- Roman portraits

---

### 6. Louvre Collections

**Website:** https://collections.louvre.fr/en/

**Search:** "sculpture greek head" or "sculpture roman portrait"

**Note:** Check individual image licenses

---

## How to Find the Perfect Eyes

### Search Strategy

1. **Search for heads/busts, not full statues:**
   - "greek marble head"
   - "roman portrait bust"
   - "classical sculpture face"

2. **Specific periods:**
   - "archaic greek kouros" (serene, stylized)
   - "classical greek sculpture" (idealized, peaceful)
   - "hellenistic sculpture" (emotional, dramatic)
   - "roman portrait" (realistic, wise)

3. **Look for close-ups:**
   - Museums often provide detail shots
   - Check "zoom" or "IIIF viewer" options

---

## Recommended Starting Collection

### Serene/Peaceful Eyes

**Greek Classical Period (450-400 BCE):**
- Doryphoros (Spear Bearer) type
- Athena heads
- Apollo statues
- Smooth, idealized features
- Almond-shaped eyes
- Minimal lid detail

**Best sources:** Met Museum, Getty

---

### Fierce/Intense Eyes

**Hellenistic Period (323-31 BCE):**
- Alexander the Great portraits
- Dying Gaul
- Laocoon group
- Dramatic expressions
- Deep-set eyes
- Strong brow ridges

**Best sources:** Smithsonian, British Museum

---

### Wise/Aged Eyes

**Roman Republican Period:**
- Senator portraits
- Veristic portraits
- Realistic aging details
- Detailed wrinkles
- Saggy eyelids
- Life-like features

**Best sources:** Met Museum, Getty

---

### Stylized/Archaic Eyes

**Greek Archaic Period (700-480 BCE):**
- Kouros statues
- Kore statues
- Almond-shaped
- Simplified forms
- "Archaic smile"
- Clean, simple carving

**Best sources:** Getty, Met Museum

---

## How to Download and Crop

### Step 1: Find the Statue

Example: Met Museum
1. Go to https://www.metmuseum.org/art/collection
2. Search: "roman portrait marble"
3. Filter: Public Domain only
4. Click on a good example

### Step 2: Download High-Res

1. Click "Download" button
2. Choose largest size (usually 4000px+)
3. Save to your computer

### Step 3: Crop the Eyes

Use any image editor (Photoshop, GIMP, etc.):

1. Open the full statue image
2. Zoom in on one eye
3. Crop just the eye area:
   - Include: eyeball, eyelids, tear duct, socket
   - Leave some surrounding area for context
   - Square or slightly rectangular crop

4. Save as PNG:
   - `greek_serene_left.png`
   - `roman_fierce_right.png`
   - etc.

5. Repeat for other eye (if different)

### Step 4: Organize

Place cropped eyes in:
```
./backend/scripts/seed_data/eyes/
├── greek_serene_left.png
├── greek_serene_right.png
├── roman_fierce_left.png
├── roman_fierce_right.png
├── greek_peaceful_left.png
└── ...
```

### Step 5: Run Seed Script

```bash
cd backend
python scripts/seed_eye_catalog.py
```

---

## Recommended Starting Collection (10 Eyes)

To start, get these 10 eyes:

### Greek Classical (Serene)
1. Left eye - Greek marble head
2. Right eye - Greek marble head

### Greek Archaic (Stylized/Peaceful)
3. Left eye - Kouros statue
4. Right eye - Kouros statue

### Hellenistic (Fierce/Dramatic)
5. Left eye - Alexander portrait
6. Right eye - Alexander portrait

### Roman Republican (Wise/Aged)
7. Left eye - Roman senator bust
8. Right eye - Roman senator bust

### Roman Imperial (Powerful)
9. Left eye - Emperor portrait
10. Right eye - Emperor portrait

This gives you 5 emotional ranges × 2 eyes = 10 eyes to start!

---

## Quick Links

- **Met Museum Collection:** https://www.metmuseum.org/art/collection/search#!?department=13&showOnly=openAccess
- **Smithsonian Open Access:** https://www.si.edu/openaccess
- **Getty Open Content:** https://www.getty.edu/about/whatwedo/opencontent.html
- **Rijksmuseum API:** https://data.rijksmuseum.nl/object-metadata/api/

---

## Legal Notes

- **CC0/Public Domain:** Use freely for any purpose
- **CC BY:** Must credit the source
- **CC BY-NC:** Non-commercial use only
- **Always check** individual image licenses

For commercial carving business, stick to **CC0** or **Public Domain** images.

---

## Tips for Best Results

1. **High resolution:** Download largest size available (2000px+ minimum)
2. **Good lighting:** Look for evenly lit photographs
3. **Straight-on angle:** Avoid extreme angles
4. **Clear detail:** Can you see the eyelid lines clearly?
5. **Minimal damage:** Choose well-preserved sculptures

---

## Next Steps

1. Browse the museums above
2. Download 10-20 good eye examples
3. Crop them in an image editor
4. Place in `backend/scripts/seed_data/eyes/`
5. Run the seed script
6. Your catalog is ready!

**You'll have a library of proven carved eyes from master sculptors spanning 2000+ years!**
