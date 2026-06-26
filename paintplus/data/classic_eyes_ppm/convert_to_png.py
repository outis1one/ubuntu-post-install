#!/usr/bin/env python3
"""Convert PPM files to PNG using PIL."""
from pathlib import Path
from PIL import Image

ppm_dir = Path(__file__).parent
for ppm_file in ppm_dir.glob("*.ppm"):
    png_file = ppm_file.with_suffix('.png')
    img = Image.open(ppm_file)
    img.save(png_file, 'PNG')
    print(f"Converted: {ppm_file.name} -> {png_file.name}")
