import React, { useEffect, useRef, useState, useCallback, forwardRef, useImperativeHandle } from 'react';
import { fabric } from 'fabric';
import './ImageCanvas.css';

const ImageCanvas = forwardRef(({
  imageUrl,
  onSelectionChange,
  selectionMode,
  advancedToolMode,
  onAdvancedToolClick,
  zoom = 100,
  onZoomChange,
  externalSelection,
  isProcessing
}, ref) => {
  const canvasRef = useRef(null);
  const fabricCanvasRef = useRef(null);
  const [currentSelection, setCurrentSelection] = useState(null);
  const [currentZoom, setCurrentZoom] = useState(1);
  const currentSelectionRef = useRef(null);
  const lassoPoints = useRef([]);
  const onZoomChangeRef = useRef(onZoomChange);
  const imageRef = useRef(null);
  const baseScaleRef = useRef(1);
  const isDrawingRef = useRef(false);

  // Keep ref updated
  useEffect(() => {
    onZoomChangeRef.current = onZoomChange;
  }, [onZoomChange]);

  // Expose methods to parent
  useImperativeHandle(ref, () => ({
    getCanvas: () => fabricCanvasRef.current,
    clearSelection: () => clearSelection(),
  }));

  // Update selection ref when state changes
  useEffect(() => {
    currentSelectionRef.current = currentSelection;
  }, [currentSelection]);

  // Initialize canvas
  useEffect(() => {
    if (!canvasRef.current) return;

    const canvas = new fabric.Canvas(canvasRef.current, {
      selection: false,
      backgroundColor: 'transparent',
      preserveObjectStacking: true,
    });
    fabricCanvasRef.current = canvas;

    const handleResize = () => {
      const container = canvasRef.current?.parentElement;
      if (container) {
        const width = container.clientWidth;
        const height = container.clientHeight;
        canvas.setWidth(width);
        canvas.setHeight(height);

        // Re-center image if it exists
        if (imageRef.current) {
          centerImage(canvas, imageRef.current, zoom / 100);
        }
        canvas.renderAll();
      }
    };

    // Initial resize - use requestAnimationFrame to ensure DOM is ready
    requestAnimationFrame(() => {
      handleResize();
    });
    window.addEventListener('resize', handleResize);

    // Mouse wheel zoom
    const handleWheel = (opt) => {
      const e = opt.e;
      e.preventDefault();
      e.stopPropagation();

      const delta = e.deltaY;
      let newZoom = canvas.getZoom();
      newZoom *= 0.999 ** delta;

      // Clamp zoom between 0.1x and 10x
      if (newZoom > 10) newZoom = 10;
      if (newZoom < 0.1) newZoom = 0.1;

      // Zoom to point under cursor
      const pointer = canvas.getPointer(e, true);
      canvas.zoomToPoint({ x: pointer.x, y: pointer.y }, newZoom);

      setCurrentZoom(newZoom);
      if (onZoomChangeRef.current) {
        onZoomChangeRef.current(newZoom);
      }
    };

    canvas.on('mouse:wheel', handleWheel);

    return () => {
      window.removeEventListener('resize', handleResize);
      canvas.off('mouse:wheel', handleWheel);
      canvas.dispose();
    };
  }, []); // Empty dependency array - only run once on mount

  // Center and scale image
  const centerImage = (canvas, img, zoomFactor) => {
    if (!img) return;

    const padding = 40;
    const availableWidth = canvas.width - padding;
    const availableHeight = canvas.height - padding;

    // Calculate base scale to fit
    const fitScale = Math.min(
      availableWidth / img.width,
      availableHeight / img.height
    );

    baseScaleRef.current = fitScale;
    const scale = fitScale * zoomFactor;

    img.scale(scale);
    img.set({
      left: (canvas.width - img.width * scale) / 2,
      top: (canvas.height - img.height * scale) / 2,
    });
  };

  // Apply zoom changes
  useEffect(() => {
    const canvas = fabricCanvasRef.current;
    if (!canvas || !imageRef.current) return;

    centerImage(canvas, imageRef.current, zoom / 100);
    canvas.renderAll();
  }, [zoom]);

  // Load image when URL changes
  useEffect(() => {
    if (!fabricCanvasRef.current || !imageUrl) return;

    const canvas = fabricCanvasRef.current;

    // Ensure canvas has dimensions before loading image
    if (canvas.width === 0 || canvas.height === 0) {
      const container = canvasRef.current?.parentElement;
      if (container) {
        canvas.setWidth(container.clientWidth || 800);
        canvas.setHeight(container.clientHeight || 600);
      }
    }

    // Add cache buster to force reload
    const cacheBustedUrl = `${imageUrl}?t=${Date.now()}`;

    fabric.Image.fromURL(cacheBustedUrl, (img) => {
      if (!img) {
        console.error('Failed to load image from URL:', cacheBustedUrl);
        return;
      }

      canvas.clear();

      // Scale image to fit canvas with padding
      const padding = 40;
      const availableWidth = (canvas.width || 800) - padding;
      const availableHeight = (canvas.height || 600) - padding;
      const scale = Math.min(
        availableWidth / img.width,
        availableHeight / img.height
      );

      img.scale(scale);
      img.set({
        left: ((canvas.width || 800) - img.width * scale) / 2,
        top: ((canvas.height || 600) - img.height * scale) / 2,
        selectable: false,
        evented: false,
        hoverCursor: 'default',
      });

      imageRef.current = img;
      canvas.add(img);
      canvas.sendToBack(img);

      centerImage(canvas, img, zoom / 100);
      canvas.renderAll();
    }, { crossOrigin: 'anonymous' });
  }, [imageUrl]);

  // Handle tool/mode changes
  useEffect(() => {
    if (!fabricCanvasRef.current) return;

    const canvas = fabricCanvasRef.current;

    // Remove all event handlers
    canvas.off('mouse:down');
    canvas.off('mouse:move');
    canvas.off('mouse:up');
    canvas.off('object:modified');
    canvas.off('object:moving');
    canvas.off('object:scaling');

    // Set up handlers based on selection mode or advanced tool mode
    if (advancedToolMode === 'smart-select') {
      setupSmartSelectMode(canvas);
    } else if (advancedToolMode === 'color-select') {
      setupColorSelectMode(canvas);
    } else if (selectionMode === 'rectangle') {
      setupRectangleMode(canvas);
    } else if (selectionMode === 'ellipse') {
      setupEllipseMode(canvas);
    } else if (selectionMode === 'lasso') {
      setupLassoMode(canvas);
    } else if (selectionMode === 'move') {
      setupMoveMode(canvas);
    } else if (selectionMode === 'pan') {
      setupPanMode(canvas);
    }
  }, [selectionMode, advancedToolMode, onAdvancedToolClick, isProcessing]);

  const setupMoveMode = (canvas) => {
    // In move mode, allow selecting and moving selection objects
    const sel = currentSelectionRef.current;
    if (sel) {
      sel.set({ selectable: true, evented: true });
      canvas.setActiveObject(sel);
    }

    canvas.on('object:modified', (e) => {
      if (e.target && e.target === currentSelectionRef.current) {
        updateTransformedSelection(e.target);
      }
    });
  };

  const setupPanMode = (canvas) => {
    let isPanning = false;
    let lastPosX, lastPosY;

    canvas.on('mouse:down', (e) => {
      isPanning = true;
      lastPosX = e.e.clientX;
      lastPosY = e.e.clientY;
      canvas.setCursor('grabbing');
    });

    canvas.on('mouse:move', (e) => {
      if (!isPanning) return;

      const deltaX = e.e.clientX - lastPosX;
      const deltaY = e.e.clientY - lastPosY;

      canvas.relativePan({ x: deltaX, y: deltaY });

      lastPosX = e.e.clientX;
      lastPosY = e.e.clientY;
    });

    canvas.on('mouse:up', () => {
      isPanning = false;
      canvas.setCursor('grab');
    });

    canvas.setCursor('grab');
  };

  const setupSmartSelectMode = (canvas) => {
    canvas.on('mouse:down', (e) => {
      if (isProcessing) return;

      const pointer = canvas.getPointer(e.e);
      const img = imageRef.current;

      if (!img) return;

      // Convert to image coordinates
      const imgScale = img.scaleX;
      const imgLeft = img.left;
      const imgTop = img.top;

      const x = Math.round((pointer.x - imgLeft) / imgScale);
      const y = Math.round((pointer.y - imgTop) / imgScale);

      // Check if click is within image bounds
      if (x >= 0 && x < img.width && y >= 0 && y < img.height) {
        onAdvancedToolClick?.(x, y, null);
      }
    });

    canvas.setCursor('crosshair');
  };

  const setupColorSelectMode = (canvas) => {
    canvas.on('mouse:down', (e) => {
      if (isProcessing) return;

      const pointer = canvas.getPointer(e.e);
      const img = imageRef.current;

      if (!img) return;

      // Convert to image coordinates
      const imgScale = img.scaleX;
      const imgLeft = img.left;
      const imgTop = img.top;

      const x = Math.round((pointer.x - imgLeft) / imgScale);
      const y = Math.round((pointer.y - imgTop) / imgScale);

      // Check if click is within image bounds
      if (x >= 0 && x < img.width && y >= 0 && y < img.height) {
        // Get pixel color from canvas
        const ctx = canvas.getContext('2d');
        if (ctx) {
          // Calculate actual canvas position accounting for viewport transform
          const vpt = canvas.viewportTransform;
          const canvasX = pointer.x * vpt[0] + vpt[4];
          const canvasY = pointer.y * vpt[3] + vpt[5];

          const pixelData = ctx.getImageData(canvasX, canvasY, 1, 1).data;
          const color = {
            r: pixelData[0],
            g: pixelData[1],
            b: pixelData[2]
          };
          onAdvancedToolClick?.(x, y, color);
        }
      }
    });

    canvas.setCursor('crosshair');
  };

  const setupRectangleMode = (canvas) => {
    let rect = null;
    let isDown = false;
    let startX, startY;

    canvas.on('mouse:down', (e) => {
      // Check if clicking on existing selection
      const sel = currentSelectionRef.current;
      if (e.target && e.target === sel) {
        // Allow moving/transforming
        return;
      }

      // Clear previous selection
      if (sel) {
        canvas.remove(sel);
        setCurrentSelection(null);
      }

      isDown = true;
      isDrawingRef.current = true;
      const pointer = canvas.getPointer(e.e);
      startX = pointer.x;
      startY = pointer.y;

      rect = new fabric.Rect({
        left: startX,
        top: startY,
        width: 0,
        height: 0,
        fill: 'rgba(0, 136, 255, 0.2)',
        stroke: '#0088ff',
        strokeWidth: 2,
        strokeDashArray: [5, 5],
        selectable: true,
        hasControls: true,
        hasBorders: true,
        cornerColor: '#0088ff',
        cornerSize: 8,
        transparentCorners: false,
        borderColor: '#0088ff',
      });

      canvas.add(rect);
    });

    canvas.on('mouse:move', (e) => {
      if (!isDown || !rect) return;

      const pointer = canvas.getPointer(e.e);
      const width = pointer.x - startX;
      const height = pointer.y - startY;

      rect.set({
        width: Math.abs(width),
        height: Math.abs(height),
        left: width < 0 ? pointer.x : startX,
        top: height < 0 ? pointer.y : startY,
      });

      canvas.renderAll();
    });

    canvas.on('mouse:up', () => {
      if (isDown && rect && rect.width > 5 && rect.height > 5) {
        isDown = false;
        isDrawingRef.current = false;
        setCurrentSelection(rect);
        canvas.setActiveObject(rect);
        updateSelection(rect, 'rectangle');
      } else if (isDown && rect) {
        // Selection too small, remove it
        canvas.remove(rect);
        isDown = false;
        isDrawingRef.current = false;
      }
    });

    canvas.on('object:modified', (e) => {
      if (e.target === currentSelectionRef.current) {
        updateTransformedSelection(e.target);
      }
    });
  };

  const setupEllipseMode = (canvas) => {
    let ellipse = null;
    let isDown = false;
    let startX, startY;

    canvas.on('mouse:down', (e) => {
      const sel = currentSelectionRef.current;
      if (e.target && e.target === sel) {
        return;
      }

      if (sel) {
        canvas.remove(sel);
        setCurrentSelection(null);
      }

      isDown = true;
      const pointer = canvas.getPointer(e.e);
      startX = pointer.x;
      startY = pointer.y;

      ellipse = new fabric.Ellipse({
        left: startX,
        top: startY,
        rx: 0,
        ry: 0,
        fill: 'rgba(0, 136, 255, 0.2)',
        stroke: '#0088ff',
        strokeWidth: 2,
        strokeDashArray: [5, 5],
        selectable: true,
        hasControls: true,
        hasBorders: true,
        cornerColor: '#0088ff',
        cornerSize: 8,
        transparentCorners: false,
        borderColor: '#0088ff',
      });

      canvas.add(ellipse);
    });

    canvas.on('mouse:move', (e) => {
      if (!isDown || !ellipse) return;

      const pointer = canvas.getPointer(e.e);
      const rx = Math.abs(pointer.x - startX) / 2;
      const ry = Math.abs(pointer.y - startY) / 2;

      ellipse.set({
        rx: rx,
        ry: ry,
        left: Math.min(startX, pointer.x),
        top: Math.min(startY, pointer.y),
      });

      canvas.renderAll();
    });

    canvas.on('mouse:up', () => {
      if (isDown && ellipse && ellipse.rx > 5 && ellipse.ry > 5) {
        isDown = false;
        setCurrentSelection(ellipse);
        canvas.setActiveObject(ellipse);
        updateSelection(ellipse, 'ellipse');
      } else if (isDown && ellipse) {
        canvas.remove(ellipse);
        isDown = false;
      }
    });

    canvas.on('object:modified', (e) => {
      if (e.target === currentSelectionRef.current) {
        updateTransformedSelection(e.target);
      }
    });
  };

  const setupLassoMode = (canvas) => {
    let points = [];
    let drawingLine = null;
    let polygon = null;

    canvas.on('mouse:down', (e) => {
      const sel = currentSelectionRef.current;
      if (e.target && e.target === sel) {
        return;
      }

      if (sel) {
        canvas.remove(sel);
        setCurrentSelection(null);
      }

      isDrawingRef.current = true;
      const pointer = canvas.getPointer(e.e);
      points = [{ x: pointer.x, y: pointer.y }];

      drawingLine = new fabric.Polyline(points, {
        fill: 'transparent',
        stroke: '#0088ff',
        strokeWidth: 2,
        selectable: false,
        evented: false,
      });

      canvas.add(drawingLine);
    });

    canvas.on('mouse:move', (e) => {
      if (!isDrawingRef.current) return;

      const pointer = canvas.getPointer(e.e);
      points.push({ x: pointer.x, y: pointer.y });

      canvas.remove(drawingLine);
      drawingLine = new fabric.Polyline([...points], {
        fill: 'transparent',
        stroke: '#0088ff',
        strokeWidth: 2,
        selectable: false,
        evented: false,
      });
      canvas.add(drawingLine);
      canvas.renderAll();
    });

    canvas.on('mouse:up', () => {
      if (isDrawingRef.current && points.length > 5) {
        isDrawingRef.current = false;
        lassoPoints.current = [...points];

        canvas.remove(drawingLine);

        polygon = new fabric.Polygon(points, {
          fill: 'rgba(0, 136, 255, 0.2)',
          stroke: '#0088ff',
          strokeWidth: 2,
          strokeDashArray: [5, 5],
          selectable: true,
          hasControls: true,
          hasBorders: true,
          cornerColor: '#0088ff',
          cornerSize: 8,
          transparentCorners: false,
          borderColor: '#0088ff',
        });

        canvas.add(polygon);
        canvas.setActiveObject(polygon);
        setCurrentSelection(polygon);
        updateSelection(polygon, 'lasso');
      } else if (isDrawingRef.current) {
        isDrawingRef.current = false;
        canvas.remove(drawingLine);
      }
    });

    canvas.on('object:modified', (e) => {
      if (e.target === currentSelectionRef.current) {
        updateTransformedSelection(e.target);
      }
    });
  };

  const updateSelection = (selection, type) => {
    if (!selection || !imageRef.current) return;

    const img = imageRef.current;
    const imgScale = img.scaleX;
    const imgLeft = img.left;
    const imgTop = img.top;

    let bbox, selectionData = null;

    if (type === 'rectangle') {
      bbox = {
        x: Math.round((selection.left - imgLeft) / imgScale),
        y: Math.round((selection.top - imgTop) / imgScale),
        width: Math.round(selection.width / imgScale),
        height: Math.round(selection.height / imgScale),
      };
    } else if (type === 'ellipse') {
      bbox = {
        x: Math.round((selection.left - imgLeft) / imgScale),
        y: Math.round((selection.top - imgTop) / imgScale),
        width: Math.round((selection.rx * 2) / imgScale),
        height: Math.round((selection.ry * 2) / imgScale),
      };
    } else if (type === 'lasso') {
      const bounds = selection.getBoundingRect();
      bbox = {
        x: Math.round((bounds.left - imgLeft) / imgScale),
        y: Math.round((bounds.top - imgTop) / imgScale),
        width: Math.round(bounds.width / imgScale),
        height: Math.round(bounds.height / imgScale),
      };

      const relativePoints = lassoPoints.current.map(p => [
        Math.round((p.x - imgLeft) / imgScale) - bbox.x,
        Math.round((p.y - imgTop) / imgScale) - bbox.y,
      ]);

      selectionData = { points: relativePoints };
    }

    onSelectionChange?.({
      type,
      bbox,
      selectionData,
    });
  };

  const updateTransformedSelection = (selection) => {
    if (!selection || !imageRef.current) return;

    const img = imageRef.current;
    const imgScale = img.scaleX;
    const imgLeft = img.left;
    const imgTop = img.top;

    const bounds = selection.getBoundingRect(true);

    const bbox = {
      x: Math.round((bounds.left - imgLeft) / imgScale),
      y: Math.round((bounds.top - imgTop) / imgScale),
      width: Math.round(bounds.width / imgScale),
      height: Math.round(bounds.height / imgScale),
    };

    let selectionData = null;
    const type = selection.type === 'polygon' ? 'lasso' : (selection.type === 'ellipse' ? 'ellipse' : 'rectangle');

    if (type === 'lasso' && lassoPoints.current.length > 0) {
      const matrix = selection.calcTransformMatrix();
      const transformedPoints = lassoPoints.current.map(p => {
        const transformed = fabric.util.transformPoint(
          new fabric.Point(p.x, p.y),
          matrix
        );
        return [
          Math.round((transformed.x - imgLeft) / imgScale) - bbox.x,
          Math.round((transformed.y - imgTop) / imgScale) - bbox.y,
        ];
      });
      selectionData = { points: transformedPoints };
    }

    onSelectionChange?.({
      type,
      bbox,
      selectionData,
    });
  };

  const clearSelection = () => {
    const canvas = fabricCanvasRef.current;
    const sel = currentSelectionRef.current;
    if (sel && canvas) {
      canvas.remove(sel);
      setCurrentSelection(null);
      onSelectionChange?.(null);
    }
  };

  const handleZoomIn = () => {
    if (!fabricCanvasRef.current) return;
    const canvas = fabricCanvasRef.current;
    let newZoom = canvas.getZoom() * 1.2;
    if (newZoom > 10) newZoom = 10;
    canvas.setZoom(newZoom);
    setCurrentZoom(newZoom);
    if (onZoomChangeRef.current) {
      onZoomChangeRef.current(newZoom);
    }
  };

  const handleZoomOut = () => {
    if (!fabricCanvasRef.current) return;
    const canvas = fabricCanvasRef.current;
    let newZoom = canvas.getZoom() / 1.2;
    if (newZoom < 0.1) newZoom = 0.1;
    canvas.setZoom(newZoom);
    setCurrentZoom(newZoom);
    if (onZoomChangeRef.current) {
      onZoomChangeRef.current(newZoom);
    }
  };

  const handleZoomReset = () => {
    if (!fabricCanvasRef.current) return;
    const canvas = fabricCanvasRef.current;
    canvas.setZoom(1);
    canvas.setViewportTransform([1, 0, 0, 1, 0, 0]);
    setCurrentZoom(1);
    if (onZoomChangeRef.current) {
      onZoomChangeRef.current(1);
    }
  };

  return (
    <div className="canvas-container">
      <canvas ref={canvasRef} />
      <div className="canvas-controls">
        <div className="zoom-controls">
          <button onClick={handleZoomOut} title="Zoom Out">−</button>
          <span className="zoom-level">{Math.round(currentZoom * 100)}%</span>
          <button onClick={handleZoomIn} title="Zoom In">+</button>
          <button onClick={handleZoomReset} title="Reset Zoom">⟲</button>
        </div>
        {currentSelection && (
          <button className="clear-selection-btn" onClick={clearSelection}>
            Clear Selection
          </button>
        )}
      </div>
      {(advancedToolMode === 'smart-select' || advancedToolMode === 'color-select') && (
        <div className="tool-mode-indicator">
          {advancedToolMode === 'smart-select' ? 'Click on an object to select it' : 'Click on a color to select similar pixels'}
        </div>
      )}
    </div>
  );
});

ImageCanvas.displayName = 'ImageCanvas';

export default ImageCanvas;
