# Quick Start Guide

## How to Choose the Right AI Model

### For Body Parts (Hands, Faces, Bodies)

Use **Replicate with `realistic-vision`** model:

```env
AI_PROVIDER=replicate
REPLICATE_API_KEY=your-key-here
REPLICATE_MODEL=realistic-vision
```

**Why:** This model is specifically trained on human anatomy and handles difficult features like:
- ✅ Hands (even complex finger positions)
- ✅ Faces and expressions
- ✅ Skin textures
- ✅ Body proportions

**Cost:** ~$0.020/image

### For Removing Objects

Use **Replicate with `lama`** model:

```env
AI_PROVIDER=replicate
REPLICATE_MODEL=lama
```

**Why:** Designed specifically for inpainting and removal
**Cost:** ~$0.002/image (cheapest!)

### For General Edits (Landscapes, Objects, Creative)

Use **Replicate with `sdxl-inpaint`** model (default):

```env
AI_PROVIDER=replicate
REPLICATE_MODEL=sdxl-inpaint
```

**Cost:** ~$0.025/image

---

## Auto-Model Selection

The system automatically picks the best model based on your prompt:

| Your Prompt | Auto-Selected Model | Why |
|-------------|-------------------|-----|
| "Fix the hand" | realistic-vision | Detects "hand" keyword |
| "Remove person" | lama | Detects "remove" keyword |
| "Change sky to sunset" | sdxl-inpaint | General purpose default |

**You don't need to manually specify models** - the auto-selection is optimized for quality and cost!

---

## Patch Library: Save and Reuse Parts

### What is the Patch Library?

A library where you can save image patches (regions) and reuse them across different images.

**Use Cases:**
- Save a well-generated hand to reuse later
- Save a perfect face for multiple photos
- Build a collection of good body parts
- Save textures, objects, or backgrounds
- Reuse AI-generated elements that came out great

### How to Save a Patch

#### Option 1: Save AI-Generated Result

After an AI edit completes:

```bash
POST /patches/
{
  "name": "Perfect Hand",
  "description": "Well-formed left hand, palm up",
  "source_type": "ai_generated",
  "source_edit_id": 123,
  "category": "hand",
  "tags": "left, palm, realistic"
}
```

This saves the AI-generated output (`patch_out.png`) to your library.

#### Option 2: Save Manual Selection

Select any region from your current image:

```bash
POST /patches/
{
  "name": "Good Face",
  "description": "Frontal face with good lighting",
  "source_type": "manual_selection",
  "source_project_id": 456,
  "bbox": {"x": 100, "y": 100, "width": 200, "height": 200},
  "category": "face",
  "tags": "front, smile, female"
}
```

This saves whatever is currently in that region of your image.

#### Option 3: Import from File

Upload an external image:

```bash
POST /patches/
FormData:
  name: "Downloaded Hand"
  source_type: "imported"
  file: [uploaded PNG file]
  category: "hand"
```

### How to Apply a Saved Patch

```bash
POST /patches/apply
{
  "project_id": 789,
  "patch_id": 123,
  "bbox": {"x": 300, "y": 400, "width": 200, "height": 200},
  "feather_px": 10
}
```

This places the saved patch at the specified location in your image.

### Browse Your Patch Library

```bash
# List all patches
GET /patches/

# Filter by category
GET /patches/?category=hand

# Filter by tags
GET /patches/?tags=realistic

# Get specific patch
GET /patches/123

# Get patch image
GET /patches/123/image

# Get patch thumbnail
GET /patches/123/image?thumbnail=true
```

### Organize Your Patches

**Categories:**
- `hand` - Hand images
- `face` - Facial features
- `body` - Body parts
- `object` - Objects and items
- `texture` - Textures and patterns
- `background` - Backgrounds and scenery

**Tags:** Comma-separated keywords for searching
- "left, palm, realistic"
- "front, smile, female"
- "five fingers, open hand"

---

## Complete Workflow Example

### Scenario: Fix hands in a portrait photo

**Step 1: Create project and upload image**
```bash
POST /projects/ {"name": "Portrait Edit"}
POST /projects/1/upload [upload photo]
```

**Step 2: Try to fix the hand with AI**
```bash
POST /edits/projects/1/fix
{
  "prompt": "realistic human hand with five fingers, natural pose",
  "mode": "B",  # Use full image for context
  "selection_type": "rectangle",
  "bbox": {"x": 200, "y": 300, "width": 150, "height": 200},
  "feather_px": 10
}
```

The system auto-selects `realistic-vision` model because prompt mentions "hand".

**Step 3: If result is good, save it for later**
```bash
POST /patches/
{
  "name": "Good Left Hand",
  "source_type": "ai_generated",
  "source_edit_id": 1,
  "category": "hand",
  "tags": "left, natural, realistic, five fingers"
}
```

**Step 4: Use saved hand on another photo**
```bash
# On a different project
POST /patches/apply
{
  "project_id": 2,
  "patch_id": 1,
  "bbox": {"x": 150, "y": 250, "width": 150, "height": 200},
  "feather_px": 15
}
```

---

## Cost Comparison

### Example: Fixing 10 hands in different photos

**Option A: Generate each hand with AI**
- 10 edits × $0.020 = **$0.20**

**Option B: Generate one good hand, save it, reuse it**
- 1 AI generation: $0.020
- 9 patch applications: $0.00 (no AI cost)
- **Total: $0.020** (90% savings!)

### When to Use Saved Patches vs AI

**Use Saved Patches When:**
- You have a perfect result you want to reuse
- Same angle/lighting/style needed
- Want to maintain consistency across images
- Want to avoid AI generation costs

**Use AI Generation When:**
- Need unique/different result each time
- Different angle or perspective needed
- Want variation and creativity
- Patch doesn't fit the context

---

## Pro Tips

### Building a Good Patch Library

1. **Save your best AI results** - When AI generates something great, save it immediately
2. **Organize with categories** - Use consistent categories for easy finding
3. **Tag descriptively** - Include orientation (left/right), pose, lighting, etc.
4. **Create variations** - Save multiple versions of common needs (left hand, right hand, etc.)
5. **Build gradually** - Your library becomes more valuable over time

### Maximizing Quality

1. **For hands:** Always use `realistic-vision` model or save good results
2. **For faces:** Use Mode B (full image context) for better matching
3. **Use high feather values** (15-20px) when applying saved patches
4. **Test positioning** before finalizing - patches work best when lighting/angle matches

### Saving Money

1. **Build a patch library** of common needs
2. **Use `lama` for removals** instead of expensive models
3. **Let auto-selection work** - it picks the cheapest appropriate model
4. **Reuse successful patches** instead of regenerating

---

## API Quick Reference

```bash
# List available patches
GET /patches/

# Get patch details
GET /patches/{id}

# Get patch image
GET /patches/{id}/image
GET /patches/{id}/image?thumbnail=true

# Create patch from AI edit
POST /patches/
{
  "name": "My Patch",
  "source_type": "ai_generated",
  "source_edit_id": 123,
  "category": "hand"
}

# Create patch from manual selection
POST /patches/
{
  "name": "My Patch",
  "source_type": "manual_selection",
  "source_project_id": 456,
  "bbox": {"x": 100, "y": 100, "width": 200, "height": 200}
}

# Apply saved patch
POST /patches/apply
{
  "project_id": 789,
  "patch_id": 123,
  "bbox": {"x": 300, "y": 400, "width": 200, "height": 200},
  "feather_px": 10
}

# Delete patch
DELETE /patches/{id}

# Update patch metadata
PUT /patches/{id}
{
  "name": "Updated Name",
  "tags": "new, tags",
  "category": "hand"
}
```

---

## Summary

✅ **For hands/faces/bodies:** Use `realistic-vision` model
✅ **For removal:** Use `lama` model
✅ **For general edits:** Use `sdxl-inpaint` (default)
✅ **Auto-selection works great** - just write natural prompts
✅ **Save good AI results** to patch library for reuse
✅ **Save manual selections** from any image
✅ **Reuse patches across images** to save money and maintain consistency

**You now have the best of both worlds:**
- AI generation when you need something new
- Saved patches when you need consistency or want to save money
