#!/bin/bash
# =============================================================================
# AI Photo Edit - Container Startup Script
# =============================================================================
# This script runs when the container starts. It:
# 1. Initializes the database
# 2. Downloads SAM model automatically (can be disabled with AUTO_DOWNLOAD_SAM=false)
# 3. Downloads U2Net model automatically (can be disabled with AUTO_DOWNLOAD_U2NET=false)
# 4. Downloads sample eye images if the catalog is empty
# 5. Starts the FastAPI server
# =============================================================================

set -e

echo "=========================================="
echo "AI Photo Edit - Starting Up"
echo "=========================================="

# Ensure data directories exist
mkdir -p /app/data/projects
mkdir -p /app/data/patches
mkdir -p /app/data/models
mkdir -p /app/data/patch_library

# Initialize database FIRST (before eye import)
echo ""
echo "Initializing database..."
echo "------------------------------------------"
cd /app && python /scripts/init_database.py || echo "Warning: Database init failed (non-fatal)"

# Check and download SAM model automatically
echo ""
echo "Checking SAM model (Smart Select)..."
echo "------------------------------------------"
if [ -f "/app/data/models/sam_model.pth" ] || \
   [ -f "/app/data/models/sam_vit_b_01ec64.pth" ] || \
   [ -f "/app/data/models/sam_vit_l_0b3195.pth" ] || \
   [ -f "/app/data/models/sam_vit_h_4b8939.pth" ]; then
    echo "✓ SAM model found - Smart Select will use local AI (free, offline)"
else
    # Auto-download SAM unless explicitly disabled
    AUTO_DOWNLOAD_SAM="${AUTO_DOWNLOAD_SAM:-true}"
    if [ "$AUTO_DOWNLOAD_SAM" = "true" ]; then
        echo "SAM model not found. Downloading automatically..."
        echo "(This is a one-time ~375MB download that persists across rebuilds)"
        echo ""
        python /scripts/download_sam_model.py vit_b || {
            echo ""
            echo "⚠ SAM download failed (non-fatal)"
            echo "  Smart Select will fall back to Replicate API (requires REPLICATE_API_KEY)"
            echo "  To retry later: docker exec -it ai-photo-edit-backend python /scripts/download_sam_model.py"
        }
    else
        echo ""
        echo "⚠ SAM model not found (AUTO_DOWNLOAD_SAM=false)"
        echo ""
        echo "  Smart Select will use Replicate API (requires REPLICATE_API_KEY)"
        echo ""
        echo "  To enable FREE offline Smart Select, run:"
        echo "    docker exec -it ai-photo-edit-backend python /scripts/download_sam_model.py"
        echo ""
    fi
fi

echo ""
echo "Checking U2Net model (Remove Background)..."
echo "------------------------------------------"
if [ -f "/app/data/models/u2net.onnx" ] || [ -f "/app/data/models/u2netp.onnx" ]; then
    echo "✓ U2Net model found - Remove Background will use local AI (free, offline)"
else
    # Auto-download U2Net unless explicitly disabled
    AUTO_DOWNLOAD_U2NET="${AUTO_DOWNLOAD_U2NET:-true}"
    if [ "$AUTO_DOWNLOAD_U2NET" = "true" ]; then
        echo "U2Net model not found. Downloading automatically..."
        echo "(This is a one-time ~176MB download that persists across rebuilds)"
        echo ""
        python /scripts/download_u2net_model.py u2net || {
            echo ""
            echo "⚠ U2Net download failed (non-fatal)"
            echo "  Remove Background will fall back to rembg (if installed)"
            echo "  To retry later: docker exec -it ai-photo-edit-backend python /scripts/download_u2net_model.py u2net"
        }
    else
        echo ""
        echo "⚠ U2Net model not found (AUTO_DOWNLOAD_U2NET=false)"
        echo ""
        echo "  Remove Background will fall back to rembg (if installed)"
        echo ""
        echo "  To enable FREE offline Remove Background, run:"
        echo "    docker exec -it ai-photo-edit-backend python /scripts/download_u2net_model.py u2net"
        echo ""
    fi
fi

echo ""
echo "Checking GPU capabilities..."
echo "------------------------------------------"
python /scripts/gpu_setup.py || echo "Warning: GPU detection failed (non-fatal)"

echo ""
echo "=========================================="
echo "Starting FastAPI server..."
echo "=========================================="

# Start the server
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
