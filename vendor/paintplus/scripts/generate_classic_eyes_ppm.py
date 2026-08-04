#!/usr/bin/env python3
"""
Generate classic eye images using only the Python standard library.
Creates PPM format images that can be converted to PNG when PIL is available.

This script requires NO external dependencies - it uses the PPM image format
which is a simple text/binary format readable by most image tools.

Usage:
    python scripts/generate_classic_eyes_ppm.py

The generated PPM files can be converted to PNG using:
    - PIL/Pillow: Image.open('eye.ppm').save('eye.png')
    - ImageMagick: convert eye.ppm eye.png
    - GIMP: Open and export as PNG
"""

import os
import math
from pathlib import Path


def create_ppm(width: int, height: int) -> list:
    """Create an empty PPM image as a 2D list of (R, G, B) tuples."""
    return [[(0, 0, 0) for _ in range(width)] for _ in range(height)]


def set_pixel(img: list, x: int, y: int, color: tuple):
    """Set a pixel in the image, with bounds checking."""
    height = len(img)
    width = len(img[0]) if height > 0 else 0
    if 0 <= x < width and 0 <= y < height:
        img[y][x] = color


def draw_filled_circle(img: list, cx: int, cy: int, radius: int, color: tuple):
    """Draw a filled circle."""
    for y in range(-radius, radius + 1):
        for x in range(-radius, radius + 1):
            if x*x + y*y <= radius*radius:
                set_pixel(img, cx + x, cy + y, color)


def draw_circle_ring(img: list, cx: int, cy: int, radius: int, color: tuple, thickness: int = 1):
    """Draw a circle outline."""
    for y in range(-radius - thickness, radius + thickness + 1):
        for x in range(-radius - thickness, radius + thickness + 1):
            dist_sq = x*x + y*y
            if (radius - thickness)**2 <= dist_sq <= (radius + thickness)**2:
                set_pixel(img, cx + x, cy + y, color)


def blend_color(c1: tuple, c2: tuple, ratio: float) -> tuple:
    """Blend two colors. ratio=0 gives c1, ratio=1 gives c2."""
    return (
        int(c1[0] * (1 - ratio) + c2[0] * ratio),
        int(c1[1] * (1 - ratio) + c2[1] * ratio),
        int(c1[2] * (1 - ratio) + c2[2] * ratio)
    )


def save_ppm(img: list, filepath: str):
    """Save image as PPM format (P6 binary)."""
    height = len(img)
    width = len(img[0]) if height > 0 else 0

    with open(filepath, 'wb') as f:
        # PPM header
        f.write(f"P6\n{width} {height}\n255\n".encode())
        # Pixel data
        for row in img:
            for r, g, b in row:
                f.write(bytes([r, g, b]))


def save_ppm_text(img: list, filepath: str):
    """Save image as PPM format (P3 text - more portable)."""
    height = len(img)
    width = len(img[0]) if height > 0 else 0

    with open(filepath, 'w') as f:
        f.write(f"P3\n{width} {height}\n255\n")
        for row in img:
            line = ' '.join(f"{r} {g} {b}" for r, g, b in row)
            f.write(line + '\n')


def create_classic_eye(
    size: int = 200,
    iris_color: tuple = (70, 130, 180),
    style: str = "realistic"
) -> list:
    """
    Generate a classic stylized eye image.

    Args:
        size: Image size (square)
        iris_color: RGB color for the iris
        style: "realistic", "anime", "cartoon"

    Returns:
        2D list of (R, G, B) tuples
    """
    img = create_ppm(size, size)

    cx, cy = size // 2, size // 2
    eye_radius = size // 2 - 5
    iris_radius = int(eye_radius * 0.7)
    pupil_radius = int(iris_radius * 0.35)

    if style == "realistic":
        # White of the eye (sclera)
        sclera_color = (250, 245, 240)
        draw_filled_circle(img, cx, cy, eye_radius, sclera_color)

        # Sclera outline
        draw_circle_ring(img, cx, cy, eye_radius, (180, 160, 150), 2)

        # Iris with gradient effect (simplified)
        for r in range(iris_radius, 0, -1):
            ratio = r / iris_radius
            color = blend_color((40, 40, 40), iris_color, ratio)
            draw_circle_ring(img, cx, cy, r, color, 1)

        # Pupil
        draw_filled_circle(img, cx, cy, pupil_radius, (10, 10, 10))

        # Highlight
        hl_x = cx - pupil_radius // 2
        hl_y = cy - pupil_radius // 2
        hl_r = pupil_radius // 3
        draw_filled_circle(img, hl_x, hl_y, hl_r, (255, 255, 255))

    elif style == "anime":
        # Larger iris for anime style
        iris_radius = int(eye_radius * 0.85)

        # Sclera
        draw_filled_circle(img, cx, cy, eye_radius, (255, 255, 255))
        draw_circle_ring(img, cx, cy, eye_radius, (0, 0, 0), 3)

        # Large iris
        draw_filled_circle(img, cx, cy, iris_radius, iris_color)

        # Pupil
        pupil_radius = int(iris_radius * 0.25)
        draw_filled_circle(img, cx, cy, pupil_radius, (0, 0, 0))

        # Large highlight
        hl_x = cx - iris_radius // 3
        hl_y = cy - iris_radius // 3
        hl_r = iris_radius // 3
        draw_filled_circle(img, hl_x, hl_y, hl_r, (255, 255, 255))

        # Secondary highlight
        hl2_x = cx + iris_radius // 4
        hl2_y = cy + iris_radius // 4
        hl2_r = iris_radius // 6
        draw_filled_circle(img, hl2_x, hl2_y, hl2_r, (220, 220, 220))

    elif style == "cartoon":
        # Simple cartoon eye
        draw_filled_circle(img, cx, cy, eye_radius, (255, 255, 255))
        draw_circle_ring(img, cx, cy, eye_radius, (0, 0, 0), 4)

        draw_filled_circle(img, cx, cy, iris_radius, iris_color)
        draw_circle_ring(img, cx, cy, iris_radius, (0, 0, 0), 2)

        draw_filled_circle(img, cx, cy, pupil_radius, (0, 0, 0))

        # Highlight
        hl_x = cx - pupil_radius
        hl_y = cy - pupil_radius
        hl_r = pupil_radius // 2
        draw_filled_circle(img, hl_x, hl_y, hl_r, (255, 255, 255))

    return img


def main():
    """Generate a set of classic eye images."""
    output_dir = Path(__file__).parent.parent / "data" / "classic_eyes_ppm"
    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("Classic Eye Generator (PPM Format)")
    print("=" * 60)
    print(f"Output directory: {output_dir}")

    # Eye colors
    colors = {
        "blue": (70, 130, 180),
        "green": (60, 140, 90),
        "brown": (139, 90, 43),
        "hazel": (150, 120, 70),
        "grey": (120, 130, 140),
        "amber": (180, 130, 50),
    }

    styles = ["realistic", "anime", "cartoon"]

    metadata = []
    generated = 0

    print("\nGenerating eyes...")

    for style in styles:
        for color_name, color_rgb in colors.items():
            name = f"classic_{style}_{color_name}"
            filename = f"{name}.ppm"
            filepath = output_dir / filename

            img = create_classic_eye(size=200, iris_color=color_rgb, style=style)
            save_ppm(img, str(filepath))

            metadata.append({
                'filename': filename.replace('.ppm', '.png'),  # For after conversion
                'ppm_filename': filename,
                'name': f"Classic {style.title()} Eye - {color_name.title()}",
                'description': f"A {style} style eye with {color_name} iris color",
                'tags': f"eye,classic,{style},{color_name},medium",
                'width': 200,
                'height': 200
            })

            generated += 1
            print(f"  Generated: {name}.ppm")

    # Save metadata
    import json
    metadata_path = output_dir / "metadata.json"
    with open(metadata_path, 'w') as f:
        json.dump(metadata, f, indent=2)

    print(f"\n  Metadata saved to: {metadata_path}")
    print(f"\nGenerated {generated} eye images in PPM format.")

    # Create conversion script
    convert_script = output_dir / "convert_to_png.py"
    with open(convert_script, 'w') as f:
        f.write('''#!/usr/bin/env python3
"""Convert PPM files to PNG using PIL."""
from pathlib import Path
from PIL import Image

ppm_dir = Path(__file__).parent
for ppm_file in ppm_dir.glob("*.ppm"):
    png_file = ppm_file.with_suffix('.png')
    img = Image.open(ppm_file)
    img.save(png_file, 'PNG')
    print(f"Converted: {ppm_file.name} -> {png_file.name}")
''')

    print(f"\n  Conversion script: {convert_script}")
    print("\nTo convert PPM to PNG, run inside the backend container:")
    print(f"  python {convert_script}")
    print("\nOr use ImageMagick:")
    print(f"  cd {output_dir} && for f in *.ppm; do convert \"$f\" \"${{f%.ppm}}.png\"; done")


if __name__ == "__main__":
    main()
