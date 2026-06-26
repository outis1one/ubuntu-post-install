# ==============================================================================
# AI Photo Edit - Unified Container
# Builds miniPaint frontend and serves it alongside FastAPI backend
# ==============================================================================

# Stage 1: Build miniPaint frontend
FROM node:20-alpine AS frontend-build

WORKDIR /frontend

# Copy package files and install dependencies
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install

# Copy frontend source and build
COPY frontend/ ./
RUN npm run build

# Stage 2: Python backend with frontend static files
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies for OpenCV, rembg, SAM, and image processing
# Note: onnxruntime 1.17+ fixed executable stack issues, no longer need execstack
RUN apt-get update && apt-get install -y \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Verify rembg loads correctly (model downloads on first use)
# rembg now supports BiRefNet models which are state-of-the-art for background removal
RUN python -c "from rembg import remove; print('rembg ready')" || echo "WARNING: rembg not available - Remove Background will be disabled"

# Copy backend application
COPY backend/ .

# Copy entrypoint script
COPY backend/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy scripts
COPY scripts/ /scripts/

# Copy miniPaint frontend files from stage 1
COPY --from=frontend-build /frontend/index.html /app/static/
COPY --from=frontend-build /frontend/dist /app/static/dist
COPY --from=frontend-build /frontend/images /app/static/images
COPY --from=frontend-build /frontend/src/css /app/static/src/css

# Create data directories
RUN mkdir -p /app/data/projects /app/data/patches /app/data/models

# Expose port
EXPOSE 8000

# Use entrypoint script
ENTRYPOINT ["/entrypoint.sh"]
