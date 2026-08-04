# Model Selection Guide for Body Parts and Editing Tasks

## Quick Reference: Best Models by Use Case

### Human Features (Faces, Hands, Bodies)

**Best Choice: `realistic-vision` (Replicate)**

```env
AI_PROVIDER=replicate
REPLICATE_API_KEY=your-key
REPLICATE_MODEL=realistic-vision
```

**Why:** Trained specifically on human anatomy and realistic photos. Handles difficult features like:
- ✅ Hands (notoriously hard for AI)
- ✅ Faces and facial features
- ✅ Skin textures and tones
- ✅ Body proportions
- ✅ Portraits

**Examples:**
- "Fix the hand position"
- "Remove red eye"
- "Smooth skin blemishes"
- "Adjust facial expression"
- "Fix fingers"

**Cost:** ~$0.020/image
**Quality:** ⭐⭐⭐⭐⭐

---

### Object Removal

**Best Choice: `lama` (Replicate)**

```env
AI_PROVIDER=replicate
REPLICATE_MODEL=lama
```

**Why:** Specifically designed for inpainting and object removal. Excellent at:
- ✅ Removing objects cleanly
- ✅ Filling in backgrounds naturally
- ✅ Maintaining surrounding context
- ✅ Fast and cheap

**Examples:**
- "Remove the person"
- "Delete the watermark"
- "Erase the object"
- "Clean up the background"

**Cost:** ~$0.002/image (cheapest!)
**Quality:** ⭐⭐⭐⭐

---

### General Purpose Editing

**Best Choice: `sdxl-inpaint` (Replicate or Stability AI)**

```env
# Option 1: Replicate
AI_PROVIDER=replicate
REPLICATE_MODEL=sdxl-inpaint

# Option 2: Stability AI Direct
AI_PROVIDER=stability
STABILITY_MODEL=sdxl
```

**Why:** SDXL (Stable Diffusion XL) is the best all-around model for:
- ✅ Landscapes and scenery
- ✅ Objects and textures
- ✅ Creative edits
- ✅ Style changes
- ✅ Adding elements

**Examples:**
- "Change sky to sunset"
- "Add flowers"
- "Make it autumn"
- "Replace with grass"

**Cost:**
- Replicate: ~$0.025/image
- Stability AI: ~$0.040/image

**Quality:** ⭐⭐⭐⭐⭐

---

## Detailed Comparison by Body Part

### Hands ✋

**Challenge:** Hands are the hardest thing for AI to generate correctly. Common issues:
- Wrong number of fingers
- Unnatural finger positions
- Distorted proportions
- Weird joints

**Best Models (in order):**

1. **Realistic Vision** (Replicate) - ⭐⭐⭐⭐⭐
   - Best overall for hands
   - Understands hand anatomy
   - Cost: ~$0.020/image

2. **SDXL Inpainting** (Replicate/Stability) - ⭐⭐⭐
   - Decent but less consistent
   - Cost: ~$0.025-0.040/image

3. **DALL-E 2** (OpenAI) - ⭐⭐
   - Often struggles with hands
   - Not recommended

**Tips for Better Hand Edits:**
- Use detailed prompts: "realistic human hand with five fingers"
- Add negative prompts if provider supports: "deformed, extra fingers, missing fingers"
- Use Mode B (full image context) for better results
- Consider editing in multiple passes if needed

---

### Faces 😊

**Challenge:** Faces need to look natural and maintain proper proportions

**Best Models:**

1. **Realistic Vision** (Replicate) - ⭐⭐⭐⭐⭐
   - Excellent for facial features
   - Natural skin textures
   - Good expression handling

2. **SDXL Inpainting** - ⭐⭐⭐⭐
   - Good for general facial edits
   - Better for style than realism

**Use Cases:**
- Remove blemishes
- Fix red eye
- Adjust expressions
- Change hair
- Smooth wrinkles

---

### Full Body / Torso 🧍

**Best Model:** Realistic Vision

**Why:** Maintains body proportions and realistic anatomy

**Examples:**
- "Fix the clothing wrinkles"
- "Change shirt color to blue"
- "Remove the stain"

---

### Hearts ♥️ (Decorative Elements)

**Best Model:** SDXL Inpainting

**Why:** Great for creative and decorative elements

**Examples:**
- "Add heart shape"
- "Draw a heart pattern"
- "Replace with hearts"

---

## Auto-Selection Feature

The system automatically selects the best model based on your prompt:

### Keywords that trigger `realistic-vision`:
- hand, hands, finger, fingers
- face, facial, portrait, eyes, nose, mouth
- body, person, human, skin, people
- realistic, photo, photograph

### Keywords that trigger `lama` (removal):
- remove, delete, erase, cleanup
- disappear, hide, clear

### Default: `sdxl-inpaint`
- Everything else uses SDXL for best general quality

**Example Auto-Selection:**
```python
# User prompt: "Fix the hand" → auto-selects realistic-vision
# User prompt: "Remove the person" → auto-selects lama
# User prompt: "Change to sunset" → auto-selects sdxl-inpaint
```

---

## Manual Model Override

### Via Environment Variable
Set default model in `.env`:
```env
REPLICATE_MODEL=realistic-vision
```

### Via API Request
Override per-edit in the API:
```json
{
  "prompt": "Fix the hand",
  "ai_provider": "replicate",
  "ai_model": "realistic-vision",
  "mode": "A",
  ...
}
```

### Via Frontend (Future Feature)
Model selector dropdown in the UI.

---

## Cost Optimization Strategies

### For Low-Volume Users (< 100 edits/month)
**Recommendation:** Use Replicate with auto-selection

**Why:**
- No minimum purchase
- Pay only for what you use
- Auto-selects cheapest appropriate model

**Estimated Cost:** $1-3/month

---

### For Medium-Volume Users (100-1000 edits/month)
**Recommendation:** Replicate or Stability AI

**Strategy:**
- Use `lama` for removals ($0.002/image)
- Use `realistic-vision` for humans ($0.020/image)
- Use `sdxl-inpaint` for general ($0.025/image)

**Estimated Cost:** $10-30/month

---

### For High-Volume Users (1000+ edits/month)
**Recommendation:** Consider local GPU or cloud GPU

**Why:**
- No per-image cost
- Best quality control
- Privacy

**Setup:**
- Local: RTX 3060+ GPU ($300-2000 one-time)
- Cloud: RunPod/Vast.ai ($0.30-1.00/hour)

---

## Quality Comparison Table

| Use Case | DALL-E 2 | Stability SDXL | Replicate SDXL | Replicate Realistic | Replicate LaMa |
|----------|----------|----------------|----------------|---------------------|----------------|
| Hands | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| Faces | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| Bodies | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| Objects | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | N/A |
| Landscapes | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | N/A |
| Removal | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Creative | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐ |

---

## Advanced Tips

### For Difficult Hands
1. **Use Mode B** - Provides full image context
2. **Be specific** - "realistic five-fingered hand in natural pose"
3. **Multiple passes** - Fix gross errors first, then refine
4. **Reference images** - Mode B helps AI understand the pose

### For Facial Features
1. **High feather value** - 10-15px for smooth blending
2. **Small selections** - Target specific features
3. **Natural lighting** - Mention lighting in prompt

### For Body Parts
1. **Maintain proportions** - Use Mode B for body context
2. **Clothing context** - Include clothing description in prompt
3. **Skin tone consistency** - Mention skin tone if needed

---

## Troubleshooting Common Issues

### "Hands have too many fingers"
- **Solution:** Switch to `realistic-vision` model
- **Prompt:** "realistic human hand with exactly five fingers"
- **Try:** Multiple generations, pick best result

### "Face looks unnatural"
- **Solution:** Use `realistic-vision` model
- **Increase:** Feather value to 15-20px
- **Try:** Mode B for better context

### "Removal leaves artifacts"
- **Solution:** Use `lama` model (designed for removal)
- **Alternative:** SDXL with prompt "clean background"

### "Colors don't match"
- **Increase:** Feather value to 20-30px
- **Try:** Mode B for better color context
- **Prompt:** Include color description

---

## Quick Start Examples

### Example 1: Fix a Hand
```json
{
  "prompt": "realistic human hand with five fingers, natural pose",
  "ai_provider": "replicate",
  "ai_model": "realistic-vision",
  "mode": "B",
  "feather_px": 10
}
```

### Example 2: Remove an Object
```json
{
  "prompt": "remove the object, clean background",
  "ai_provider": "replicate",
  "ai_model": "lama",
  "mode": "A",
  "feather_px": 5
}
```

### Example 3: Change Sky
```json
{
  "prompt": "sunset sky with orange and pink clouds",
  "ai_provider": "replicate",
  "ai_model": "sdxl-inpaint",
  "mode": "A",
  "feather_px": 15
}
```

---

## Summary

**For Body Parts:** Use `realistic-vision` (Replicate)
**For Removal:** Use `lama` (Replicate)
**For Everything Else:** Use `sdxl-inpaint` (Replicate or Stability)

**Let the auto-selection do its job** - it's optimized for these use cases!
