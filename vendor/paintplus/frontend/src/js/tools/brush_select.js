/**
 * Brush Select Tool - Canva-style brush-over-to-select with AI (SAM)
 * Paint over objects to select them - AI detects the actual boundaries
 * Much more intuitive than click-to-select
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../services/api.js';
import { SelectionActions, updateLayerWithResult } from './selection_actions.js';

class Brush_select_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.ctx = ctx;
        this.name = 'brush_select';

        // Brush state
        this.isDrawing = false;
        this.brushPoints = [];  // Points collected during brush stroke
        this.brushPath = [];    // Visual path for rendering

        // Store the current mask data
        this.currentMask = null;
        this.maskCanvas = null;
        this.selectionBounds = null;

        // Marching ants animation
        this.marchingAntsOffset = 0;

        // Edge canvas for drawing the mask outline
        this.edgeCanvas = null;

        // Processing state
        this.isProcessing = false;

        // Quick-action panel shown after selection
        this.selectionActions = new SelectionActions(this);
    }

    load() {
        var _this = this;

        // Mouse events
        document.addEventListener('mousedown', function (e) {
            _this.mousedown(e);
        });
        document.addEventListener('mousemove', function (e) {
            _this.mousemove(e);
        });
        document.addEventListener('mouseup', function (e) {
            _this.mouseup(e);
        });

        // Touch events
        document.addEventListener('touchstart', function (e) {
            _this.mousedown(e);
        });
        document.addEventListener('touchmove', function (e) {
            _this.mousemove(e);
        });
        document.addEventListener('touchend', function (e) {
            _this.mouseup(e);
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', function(e) {
            if (config.TOOL.name != _this.name) return;
            if (_this.Helper.is_input(e.target)) return;

            var code = e.keyCode;

            // Delete - delete selected area
            if (code == 46 && _this.currentMask) {
                e.preventDefault();
                _this.deleteSelection();
            }
            // Escape - clear selection
            if (code == 27) {
                e.preventDefault();
                _this.clearSelection();
            }
            // Ctrl+C - copy to new layer
            if (code == 67 && (e.ctrlKey || e.metaKey) && _this.currentMask) {
                e.preventDefault();
                _this.copyToLayer();
            }
            // Ctrl+X - cut to new layer
            if (code == 88 && (e.ctrlKey || e.metaKey) && _this.currentMask) {
                e.preventDefault();
                _this.cutToLayer();
            }
        });

        // Start marching ants animation
        this.startMarchingAnts();
    }

    startMarchingAnts() {
        var _this = this;

        setInterval(function() {
            if (_this.currentMask || _this.isDrawing) {
                _this.marchingAntsOffset++;
                if (_this.marchingAntsOffset > 16) {
                    _this.marchingAntsOffset = 0;
                }
                config.need_render = true;
            }
        }, 100);
    }

    mousedown(e) {
        var mouse = this.get_mouse_info(e);

        if (config.TOOL.name != this.name) return;
        if (mouse.click_valid == false) return;

        if (this.isProcessing) {
            alertify.warning('Processing... please wait');
            return;
        }

        // Check if we have an image layer
        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer first');
            return;
        }

        this.isDrawing = true;
        this.brushPoints = [];
        this.brushPath = [];

        // Get first point
        var point = this.getImagePoint(mouse.x, mouse.y);
        if (point) {
            this.brushPoints.push(point);
            this.brushPath.push({ x: mouse.x, y: mouse.y });
        }

        config.need_render = true;
    }

    mousemove(e) {
        if (!this.isDrawing) return;
        if (config.TOOL.name != this.name) return;

        var mouse = this.get_mouse_info(e);

        var point = this.getImagePoint(mouse.x, mouse.y);
        if (point) {
            // Sample points at intervals (not every pixel)
            var lastPoint = this.brushPoints[this.brushPoints.length - 1];
            var dist = Math.sqrt(Math.pow(point.x - lastPoint.x, 2) + Math.pow(point.y - lastPoint.y, 2));

            // Collect points every ~20 pixels for SAM
            if (dist >= 20) {
                this.brushPoints.push(point);
            }

            // Always update visual path
            this.brushPath.push({ x: mouse.x, y: mouse.y });
        }

        config.need_render = true;
    }

    async mouseup(e) {
        if (!this.isDrawing) return;
        if (config.TOOL.name != this.name) return;

        this.isDrawing = false;

        if (this.brushPoints.length < 2) {
            // Too few points - treat as single click
            if (this.brushPoints.length === 1) {
                await this.selectWithSinglePoint(this.brushPoints[0]);
            }
            this.brushPath = [];
            config.need_render = true;
            return;
        }

        // Check for Shift key - additive selection
        var isAdditive = e.shiftKey;

        // Process the brush stroke with SAM
        await this.processBrushSelection(isAdditive);

        this.brushPath = [];
        config.need_render = true;
    }

    getImagePoint(mouseX, mouseY) {
        var x = mouseX - config.layer.x;
        var y = mouseY - config.layer.y;

        // Adjust for layer scaling
        if (config.layer.width != config.layer.width_original) {
            x = x * (config.layer.width_original / config.layer.width);
        }
        if (config.layer.height != config.layer.height_original) {
            y = y * (config.layer.height_original / config.layer.height);
        }

        // Clamp to image bounds
        x = Math.max(0, Math.min(config.layer.width_original - 1, Math.round(x)));
        y = Math.max(0, Math.min(config.layer.height_original - 1, Math.round(y)));

        return { x: x, y: y };
    }

    /**
     * Process brush stroke - send multiple points to SAM and combine masks
     */
    async processBrushSelection(isAdditive) {
        this.isProcessing = true;
        alertify.message('AI is analyzing your selection...');

        try {
            // Get image data as base64
            var imageData = this.getLayerImageData();

            // Sample key points from brush stroke (up to 10 points for efficiency)
            var samplePoints = this.sampleKeyPoints(this.brushPoints, 10);

            // Get mask for each point and combine
            var combinedMask = null;

            for (var i = 0; i < samplePoints.length; i++) {
                var point = samplePoints[i];

                try {
                    var result = await apiService.smartSelect(imageData, point.x, point.y);

                    // Decode mask
                    var maskCanvas = await this.decodeMask(result.mask);

                    if (combinedMask === null) {
                        combinedMask = maskCanvas;
                    } else {
                        // Combine masks (union)
                        var ctx = combinedMask.getContext('2d');
                        ctx.globalCompositeOperation = 'lighter';
                        ctx.drawImage(maskCanvas, 0, 0);
                    }
                } catch (err) {
                    console.warn(`Point ${i} failed:`, err);
                }
            }

            if (combinedMask === null) {
                throw new Error('No valid masks returned');
            }

            // Apply the combined mask
            this.applyMaskCanvas(combinedMask, isAdditive);

            if (isAdditive && this.currentMask) {
                alertify.success('Added to selection! Shift+brush to add more.');
            } else {
                // Offer to float the selection for immediate manipulation (Canva-like)
                this.offerFloatSelection();
            }

        } catch (error) {
            console.error('Brush select error:', error);
            alertify.error('Selection failed: ' + error.message);
        } finally {
            this.isProcessing = false;
        }
    }

    /**
     * Select with a single point (click behavior)
     */
    async selectWithSinglePoint(point) {
        this.isProcessing = true;
        alertify.message('AI is analyzing...');

        try {
            var imageData = this.getLayerImageData();
            var result = await apiService.smartSelect(imageData, point.x, point.y);

            var maskCanvas = await this.decodeMask(result.mask);
            this.applyMaskCanvas(maskCanvas, false);

            // Offer to float the selection for immediate manipulation
            this.offerFloatSelection();

        } catch (error) {
            console.error('Select error:', error);
            alertify.error('Selection failed: ' + error.message);
        } finally {
            this.isProcessing = false;
        }
    }

    /**
     * Show quick-action panel after selection (AI operations, scale, clipboard paste, etc.)
     */
    offerFloatSelection() {
        var imageData = this.getLayerImageData();
        var maskData  = this.maskCanvas
            ? this.maskCanvas.toDataURL('image/png').split(',')[1]
            : null;
        if (maskData) {
            this.selectionActions.show(imageData, maskData);
        }
    }

    /**
     * Update the current layer canvas with a base64 result from a backend operation.
     */
    updateLayerWithResult(base64) {
        updateLayerWithResult(base64, this);
    }

    /**
     * Sample key points from brush stroke for SAM
     */
    sampleKeyPoints(points, maxPoints) {
        if (points.length <= maxPoints) {
            return points;
        }

        var sampled = [];
        var step = (points.length - 1) / (maxPoints - 1);

        for (var i = 0; i < maxPoints; i++) {
            var idx = Math.round(i * step);
            sampled.push(points[idx]);
        }

        return sampled;
    }

    /**
     * Decode base64 mask to canvas
     */
    decodeMask(maskBase64) {
        return new Promise((resolve, reject) => {
            var img = new Image();
            img.onload = function() {
                var canvas = document.createElement('canvas');
                canvas.width = config.layer.width_original;
                canvas.height = config.layer.height_original;
                var ctx = canvas.getContext('2d');
                // Scale the mask image to match the layer dimensions
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                resolve(canvas);
            };
            img.onerror = function(e) {
                console.error('Failed to decode mask image:', e);
                reject(e);
            };
            img.src = 'data:image/png;base64,' + maskBase64;
        });
    }

    /**
     * Apply a mask canvas as the current selection
     */
    applyMaskCanvas(maskCanvas, isAdditive) {
        // If additive and we have an existing mask, combine them
        if (isAdditive && this.maskCanvas) {
            var combinedCanvas = document.createElement('canvas');
            combinedCanvas.width = config.layer.width_original;
            combinedCanvas.height = config.layer.height_original;
            var combinedCtx = combinedCanvas.getContext('2d');

            // Draw existing mask
            combinedCtx.drawImage(this.maskCanvas, 0, 0);

            // Add new mask
            combinedCtx.globalCompositeOperation = 'lighter';
            combinedCtx.drawImage(maskCanvas, 0, 0);

            this.maskCanvas = combinedCanvas;
        } else {
            this.maskCanvas = maskCanvas;
        }

        this.currentMask = {
            canvas: this.maskCanvas
        };

        // Store globally for AI inpaint and other tools
        window.smartSelectMask = this.currentMask;

        // Calculate bounds and extract contour
        this.calculateSelectionBounds();
        this.extractContourPath();

        config.need_render = true;
        this.Base_layers.render();
    }

    /**
     * Get the current layer's image data as base64
     */
    getLayerImageData() {
        var canvas = document.createElement('canvas');
        var ctx = canvas.getContext('2d');

        canvas.width = config.layer.width_original;
        canvas.height = config.layer.height_original;
        ctx.drawImage(config.layer.link, 0, 0);

        return canvas.toDataURL('image/png').split(',')[1];
    }

    calculateSelectionBounds() {
        if (!this.maskCanvas) return;

        var maskCtx = this.maskCanvas.getContext('2d');
        var imageData = maskCtx.getImageData(0, 0, this.maskCanvas.width, this.maskCanvas.height);

        var minX = this.maskCanvas.width, minY = this.maskCanvas.height;
        var maxX = 0, maxY = 0;
        var hasSelection = false;

        for (var y = 0; y < this.maskCanvas.height; y++) {
            for (var x = 0; x < this.maskCanvas.width; x++) {
                var i = (y * this.maskCanvas.width + x) * 4;
                if (imageData.data[i] > 128) {
                    hasSelection = true;
                    minX = Math.min(minX, x);
                    minY = Math.min(minY, y);
                    maxX = Math.max(maxX, x);
                    maxY = Math.max(maxY, y);
                }
            }
        }

        if (hasSelection && maxX > minX && maxY > minY) {
            var scaleX = config.layer.width / config.layer.width_original;
            var scaleY = config.layer.height / config.layer.height_original;

            this.selectionBounds = {
                x: config.layer.x + minX * scaleX,
                y: config.layer.y + minY * scaleY,
                width: (maxX - minX) * scaleX,
                height: (maxY - minY) * scaleY,
                origMinX: minX,
                origMinY: minY,
                origMaxX: maxX,
                origMaxY: maxY
            };
        }
    }

    extractContourPath() {
        if (!this.maskCanvas) return;

        var maskCtx = this.maskCanvas.getContext('2d');
        var imageData = maskCtx.getImageData(0, 0, this.maskCanvas.width, this.maskCanvas.height);
        var width = this.maskCanvas.width;
        var height = this.maskCanvas.height;
        var data = imageData.data;

        this.edgeCanvas = document.createElement('canvas');
        this.edgeCanvas.width = width;
        this.edgeCanvas.height = height;
        var edgeCtx = this.edgeCanvas.getContext('2d');
        var edgeImageData = edgeCtx.createImageData(width, height);
        var edgeData = edgeImageData.data;

        for (var y = 0; y < height; y++) {
            for (var x = 0; x < width; x++) {
                var i = (y * width + x) * 4;
                var isMask = data[i] > 128;

                if (isMask) {
                    var isEdge = false;

                    if (x > 0 && data[i - 4] <= 128) isEdge = true;
                    if (x < width - 1 && data[i + 4] <= 128) isEdge = true;
                    if (y > 0 && data[i - width * 4] <= 128) isEdge = true;
                    if (y < height - 1 && data[i + width * 4] <= 128) isEdge = true;
                    if (x == 0 || x == width - 1 || y == 0 || y == height - 1) isEdge = true;

                    if (isEdge) {
                        edgeData[i] = 255;
                        edgeData[i + 1] = 255;
                        edgeData[i + 2] = 255;
                        edgeData[i + 3] = 255;
                    }
                }
            }
        }

        edgeCtx.putImageData(edgeImageData, 0, 0);
    }

    render_overlay(ctx) {
        // Draw current brush stroke
        if (this.isDrawing && this.brushPath.length > 1) {
            ctx.save();

            // Draw brush stroke preview
            ctx.strokeStyle = 'rgba(0, 200, 255, 0.8)';
            ctx.lineWidth = 20 / config.ZOOM;
            ctx.lineCap = 'round';
            ctx.lineJoin = 'round';

            ctx.beginPath();
            ctx.moveTo(this.brushPath[0].x, this.brushPath[0].y);
            for (var i = 1; i < this.brushPath.length; i++) {
                ctx.lineTo(this.brushPath[i].x, this.brushPath[i].y);
            }
            ctx.stroke();

            // Draw dots at sample points
            ctx.fillStyle = 'rgba(255, 255, 0, 0.9)';
            var scaleX = config.layer.width / config.layer.width_original;
            var scaleY = config.layer.height / config.layer.height_original;

            for (var j = 0; j < this.brushPoints.length; j++) {
                var pt = this.brushPoints[j];
                ctx.beginPath();
                ctx.arc(
                    config.layer.x + pt.x * scaleX,
                    config.layer.y + pt.y * scaleY,
                    5 / config.ZOOM, 0, Math.PI * 2
                );
                ctx.fill();
            }

            ctx.restore();
        }

        // Draw existing selection
        if (!this.currentMask || !this.maskCanvas) return;

        ctx.save();

        // Draw semi-transparent overlay on non-selected areas
        var inverseCanvas = document.createElement('canvas');
        inverseCanvas.width = this.maskCanvas.width;
        inverseCanvas.height = this.maskCanvas.height;
        var inverseCtx = inverseCanvas.getContext('2d');

        inverseCtx.fillStyle = 'rgba(0, 0, 0, 0.4)';
        inverseCtx.fillRect(0, 0, inverseCanvas.width, inverseCanvas.height);

        inverseCtx.globalCompositeOperation = 'destination-out';
        inverseCtx.drawImage(this.maskCanvas, 0, 0);

        ctx.drawImage(
            inverseCanvas,
            config.layer.x, config.layer.y,
            config.layer.width, config.layer.height
        );

        // Draw marching ants
        if (this.edgeCanvas) {
            var antsCanvas = document.createElement('canvas');
            antsCanvas.width = this.maskCanvas.width;
            antsCanvas.height = this.maskCanvas.height;
            var antsCtx = antsCanvas.getContext('2d');

            antsCtx.drawImage(this.edgeCanvas, 0, 0);
            antsCtx.globalCompositeOperation = 'source-in';

            var color = ((Math.floor(this.marchingAntsOffset / 4) % 2) === 0) ? '#00ccff' : '#ffffff';
            antsCtx.fillStyle = color;
            antsCtx.fillRect(0, 0, antsCanvas.width, antsCanvas.height);

            ctx.drawImage(
                antsCanvas,
                config.layer.x, config.layer.y,
                config.layer.width, config.layer.height
            );
        }

        ctx.restore();
    }

    copyToLayer() {
        if (!this.currentMask || !this.maskCanvas) {
            alertify.error('No selection to copy');
            return;
        }

        var layer = config.layer;
        if (layer.type != 'image') {
            alertify.error('Layer must be an image');
            return;
        }

        var bounds = this.selectionBounds;
        if (!bounds || bounds.origMinX === undefined) {
            alertify.error('Invalid selection bounds');
            return;
        }

        var maskedCanvas = document.createElement('canvas');
        maskedCanvas.width = layer.width_original;
        maskedCanvas.height = layer.height_original;
        var maskedCtx = maskedCanvas.getContext('2d');

        maskedCtx.drawImage(layer.link, 0, 0);
        maskedCtx.globalCompositeOperation = 'destination-in';
        maskedCtx.drawImage(this.maskCanvas, 0, 0);

        var cropWidth = bounds.origMaxX - bounds.origMinX + 1;
        var cropHeight = bounds.origMaxY - bounds.origMinY + 1;

        if (cropWidth <= 0 || cropHeight <= 0) {
            alertify.error('Selection is too small');
            return;
        }

        var croppedCanvas = document.createElement('canvas');
        croppedCanvas.width = cropWidth;
        croppedCanvas.height = cropHeight;
        var croppedCtx = croppedCanvas.getContext('2d');

        croppedCtx.drawImage(
            maskedCanvas,
            bounds.origMinX, bounds.origMinY, cropWidth, cropHeight,
            0, 0, cropWidth, cropHeight
        );

        var scaleX = layer.width / layer.width_original;
        var scaleY = layer.height / layer.height_original;

        var params = {
            x: Math.round(layer.x + bounds.origMinX * scaleX),
            y: Math.round(layer.y + bounds.origMinY * scaleY),
            width: Math.round(cropWidth * scaleX),
            height: Math.round(cropHeight * scaleY),
            width_original: cropWidth,
            height_original: cropHeight,
            type: 'image',
            name: layer.name + ' (Brush Selection)',
            data: croppedCanvas.toDataURL('image/png')
        };

        app.State.do_action(
            new app.Actions.Bundle_action('copy_selection_to_layer', 'Copy Selection to Layer', [
                new app.Actions.Insert_layer_action(params)
            ])
        );

        if (config.TRANSPARENCY == false) {
            config.TRANSPARENCY = true;
            this.Base_layers.render();
        }

        alertify.success('Selection copied to new layer!');
    }

    cutToLayer() {
        if (!this.currentMask || !this.maskCanvas) {
            alertify.error('No selection to cut');
            return;
        }

        var layer = config.layer;
        if (layer.type != 'image') {
            alertify.error('Layer must be an image');
            return;
        }

        var bounds = this.selectionBounds;
        if (!bounds || bounds.origMinX === undefined) {
            alertify.error('Invalid selection bounds');
            return;
        }

        var maskedCanvas = document.createElement('canvas');
        maskedCanvas.width = layer.width_original;
        maskedCanvas.height = layer.height_original;
        var maskedCtx = maskedCanvas.getContext('2d');

        maskedCtx.drawImage(layer.link, 0, 0);
        maskedCtx.globalCompositeOperation = 'destination-in';
        maskedCtx.drawImage(this.maskCanvas, 0, 0);

        var cropWidth = bounds.origMaxX - bounds.origMinX + 1;
        var cropHeight = bounds.origMaxY - bounds.origMinY + 1;

        if (cropWidth <= 0 || cropHeight <= 0) {
            alertify.error('Selection is too small');
            return;
        }

        var croppedCanvas = document.createElement('canvas');
        croppedCanvas.width = cropWidth;
        croppedCanvas.height = cropHeight;
        var croppedCtx = croppedCanvas.getContext('2d');

        croppedCtx.drawImage(
            maskedCanvas,
            bounds.origMinX, bounds.origMinY, cropWidth, cropHeight,
            0, 0, cropWidth, cropHeight
        );

        var scaleX = layer.width / layer.width_original;
        var scaleY = layer.height / layer.height_original;

        var params = {
            x: Math.round(layer.x + bounds.origMinX * scaleX),
            y: Math.round(layer.y + bounds.origMinY * scaleY),
            width: Math.round(cropWidth * scaleX),
            height: Math.round(cropHeight * scaleY),
            width_original: cropWidth,
            height_original: cropHeight,
            type: 'image',
            name: layer.name + ' (Cut)',
            data: croppedCanvas.toDataURL('image/png')
        };

        var holeCanvas = document.createElement('canvas');
        holeCanvas.width = layer.width_original;
        holeCanvas.height = layer.height_original;
        var holeCtx = holeCanvas.getContext('2d');

        holeCtx.drawImage(layer.link, 0, 0);
        holeCtx.globalCompositeOperation = 'destination-out';
        holeCtx.drawImage(this.maskCanvas, 0, 0);

        app.State.do_action(
            new app.Actions.Bundle_action('cut_selection_to_layer', 'Cut Selection to Layer', [
                new app.Actions.Update_layer_image_action(holeCanvas, layer.id),
                new app.Actions.Insert_layer_action(params)
            ])
        );

        if (config.TRANSPARENCY == false) {
            config.TRANSPARENCY = true;
            this.Base_layers.render();
        }

        this.clearSelection();
        alertify.success('Selection cut to new layer!');
    }

    deleteSelection() {
        if (!this.currentMask || !this.maskCanvas) {
            alertify.error('No selection to delete');
            return;
        }

        var layer = config.layer;
        if (layer.type != 'image') {
            alertify.error('Layer must be an image');
            return;
        }

        var holeCanvas = document.createElement('canvas');
        holeCanvas.width = layer.width_original;
        holeCanvas.height = layer.height_original;
        var holeCtx = holeCanvas.getContext('2d');

        holeCtx.drawImage(layer.link, 0, 0);
        holeCtx.globalCompositeOperation = 'destination-out';
        holeCtx.drawImage(this.maskCanvas, 0, 0);

        app.State.do_action(
            new app.Actions.Bundle_action('delete_selection', 'Delete Selection', [
                new app.Actions.Update_layer_image_action(holeCanvas, layer.id)
            ])
        );

        this.clearSelection();
        alertify.success('Selection deleted!');
    }

    clearSelection() {
        this.selectionActions.hide();
        this.currentMask = null;
        this.maskCanvas = null;
        this.edgeCanvas = null;
        this.selectionBounds = null;
        this.brushPoints = [];
        this.brushPath = [];
        window.smartSelectMask = null;
        config.need_render = true;
        this.Base_layers.render();
    }

    on_leave() {
        this.selectionActions.hide();
        this.isDrawing = false;
        this.isProcessing = false;
        this.brushPath = [];
        return [];
    }
}

export default Brush_select_class;
