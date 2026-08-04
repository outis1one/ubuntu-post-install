/**
 * Smart Select Tool - Uses SAM (Segment Anything Model) for AI-powered selection
 * Click on any object to automatically select it
 * Shift+Click to add to existing selection (multi-select)
 * Supports: Copy to layer, Cut to layer, Delete selection, AI Inpaint
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import Dialog_class from './../libs/popup.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../services/api.js';
import { SelectionActions, updateLayerWithResult } from './selection_actions.js';

class Smart_select_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.POP = new Dialog_class();
        this.ctx = ctx;
        this.name = 'smart_select';

        // Store the current mask data
        this.currentMask = null;
        this.maskCanvas = null;
        this.isProcessing = false;
        this.selectionBounds = null;

        // Marching ants animation
        this.marchingAntsOffset = 0;

        // Edge canvas for drawing the mask outline
        this.edgeCanvas = null;

        // Quick-action panel shown after selection
        this.selectionActions = new SelectionActions(this);
    }

    load() {
        var _this = this;

        // Mouse click event for selection
        document.addEventListener('mousedown', function (e) {
            _this.mousedown(e);
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
            if (code == 27 && _this.currentMask) {
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

        // Animate every 100ms for smooth marching ants
        setInterval(function() {
            if (_this.currentMask) {
                _this.marchingAntsOffset++;
                if (_this.marchingAntsOffset > 16) {
                    _this.marchingAntsOffset = 0;
                }
                config.need_render = true;
            }
        }, 100);
    }

    async mousedown(e) {
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

        // Get click coordinates relative to the image
        var x = mouse.x - config.layer.x;
        var y = mouse.y - config.layer.y;

        // Adjust for layer scaling
        if (config.layer.width != config.layer.width_original) {
            x = x * (config.layer.width_original / config.layer.width);
        }
        if (config.layer.height != config.layer.height_original) {
            y = y * (config.layer.height_original / config.layer.height);
        }

        // Make sure click is within image bounds
        if (x < 0 || y < 0 || x > config.layer.width_original || y > config.layer.height_original) {
            alertify.error('Click inside the image');
            return;
        }

        // Check for Shift key - additive selection
        var isAdditive = e.shiftKey;

        this.isProcessing = true;
        alertify.message('AI is analyzing the image...');

        try {
            // Get image data as base64
            var imageData = this.getLayerImageData();

            // Call SAM API
            var result = await apiService.smartSelect(imageData, Math.round(x), Math.round(y));

            // Apply the mask as selection (additive if Shift is held)
            this.applyMask(result.mask, result.bbox, isAdditive);

            if (isAdditive && this.currentMask) {
                alertify.success('Added to selection! Shift+Click to add more.');
            } else {
                this._showActionPanel();
            }

        } catch (error) {
            console.error('Smart select error:', error);
            alertify.error('Selection failed: ' + error.message);
        } finally {
            this.isProcessing = false;
        }
    }

    /**
     * Get the current layer's image data as base64
     */
    getLayerImageData() {
        var canvas = document.createElement('canvas');
        var ctx = canvas.getContext('2d');

        canvas.width = config.layer.width_original;
        canvas.height = config.layer.height_original;

        // Draw the layer's image
        ctx.drawImage(config.layer.link, 0, 0);

        // Return as base64 (remove data:image/png;base64, prefix)
        return canvas.toDataURL('image/png').split(',')[1];
    }

    /**
     * Apply the SAM mask as a selection
     * @param {string} maskBase64 - Base64 encoded mask image
     * @param {Object} bbox - Bounding box {x, y, width, height}
     * @param {boolean} isAdditive - If true, add to existing selection
     */
    applyMask(maskBase64, bbox, isAdditive) {
        var _this = this;

        // Create mask image
        var maskImage = new Image();
        maskImage.onload = function() {
            // Create new mask canvas
            var newMaskCanvas = document.createElement('canvas');
            newMaskCanvas.width = config.layer.width_original;
            newMaskCanvas.height = config.layer.height_original;
            var newMaskCtx = newMaskCanvas.getContext('2d');
            // Scale mask to match layer dimensions
            newMaskCtx.drawImage(maskImage, 0, 0, newMaskCanvas.width, newMaskCanvas.height);

            // If additive and we have an existing mask, combine them
            if (isAdditive && _this.maskCanvas) {
                var combinedCanvas = document.createElement('canvas');
                combinedCanvas.width = config.layer.width_original;
                combinedCanvas.height = config.layer.height_original;
                var combinedCtx = combinedCanvas.getContext('2d');

                // Draw existing mask
                combinedCtx.drawImage(_this.maskCanvas, 0, 0);

                // Add new mask using 'lighter' composite to combine white areas
                combinedCtx.globalCompositeOperation = 'lighter';
                combinedCtx.drawImage(newMaskCanvas, 0, 0);

                _this.maskCanvas = combinedCanvas;
            } else {
                _this.maskCanvas = newMaskCanvas;
            }

            _this.currentMask = {
                canvas: _this.maskCanvas,
                bbox: bbox
            };

            // Store globally for AI inpaint tool to access
            window.smartSelectMask = _this.currentMask;

            // Calculate selection bounds from mask
            _this.calculateSelectionBounds();

            // Extract contour path from the mask
            _this.extractContourPath();

            // Trigger re-render
            config.need_render = true;
            _this.Base_layers.render();
        };
        maskImage.src = 'data:image/png;base64,' + maskBase64;
    }

    /**
     * Calculate the bounding box of the selection from the mask
     */
    calculateSelectionBounds() {
        if (!this.maskCanvas) return;

        var maskCtx = this.maskCanvas.getContext('2d');
        var imageData = maskCtx.getImageData(0, 0, this.maskCanvas.width, this.maskCanvas.height);

        // Find bounding box of selection
        var minX = this.maskCanvas.width, minY = this.maskCanvas.height;
        var maxX = 0, maxY = 0;
        var hasSelection = false;

        for (var y = 0; y < this.maskCanvas.height; y++) {
            for (var x = 0; x < this.maskCanvas.width; x++) {
                var i = (y * this.maskCanvas.width + x) * 4;
                if (imageData.data[i] > 128) { // White pixel in mask
                    hasSelection = true;
                    minX = Math.min(minX, x);
                    minY = Math.min(minY, y);
                    maxX = Math.max(maxX, x);
                    maxY = Math.max(maxY, y);
                }
            }
        }

        if (hasSelection && maxX > minX && maxY > minY) {
            // Scale to current layer dimensions
            var scaleX = config.layer.width / config.layer.width_original;
            var scaleY = config.layer.height / config.layer.height_original;

            this.selectionBounds = {
                x: config.layer.x + minX * scaleX,
                y: config.layer.y + minY * scaleY,
                width: (maxX - minX) * scaleX,
                height: (maxY - minY) * scaleY,
                // Store original coordinates too
                origMinX: minX,
                origMinY: minY,
                origMaxX: maxX,
                origMaxY: maxY
            };
        }
    }

    /**
     * Extract contour points from the mask for drawing the outline
     * Uses a simple edge detection approach
     */
    extractContourPath() {
        if (!this.maskCanvas) return;

        var maskCtx = this.maskCanvas.getContext('2d');
        var imageData = maskCtx.getImageData(0, 0, this.maskCanvas.width, this.maskCanvas.height);
        var width = this.maskCanvas.width;
        var height = this.maskCanvas.height;
        var data = imageData.data;

        // Create edge canvas - pixels that are on the edge of the mask
        this.edgeCanvas = document.createElement('canvas');
        this.edgeCanvas.width = width;
        this.edgeCanvas.height = height;
        var edgeCtx = this.edgeCanvas.getContext('2d');
        var edgeImageData = edgeCtx.createImageData(width, height);
        var edgeData = edgeImageData.data;

        // Find edge pixels (mask pixels adjacent to non-mask pixels)
        for (var y = 0; y < height; y++) {
            for (var x = 0; x < width; x++) {
                var i = (y * width + x) * 4;
                var isMask = data[i] > 128;

                if (isMask) {
                    // Check if any neighbor is NOT mask (edge pixel)
                    var isEdge = false;

                    // Check 4-connected neighbors
                    if (x > 0 && data[i - 4] <= 128) isEdge = true;
                    if (x < width - 1 && data[i + 4] <= 128) isEdge = true;
                    if (y > 0 && data[i - width * 4] <= 128) isEdge = true;
                    if (y < height - 1 && data[i + width * 4] <= 128) isEdge = true;

                    // Also check boundary
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

    /**
     * Render overlay - called by miniPaint's rendering system
     * Shows the mask with marching ants outline
     */
    render_overlay(ctx) {
        if (!this.currentMask || !this.maskCanvas) return;

        ctx.save();

        // Draw semi-transparent overlay on non-selected areas
        var inverseCanvas = document.createElement('canvas');
        inverseCanvas.width = this.maskCanvas.width;
        inverseCanvas.height = this.maskCanvas.height;
        var inverseCtx = inverseCanvas.getContext('2d');

        // Fill with semi-transparent black
        inverseCtx.fillStyle = 'rgba(0, 0, 0, 0.4)';
        inverseCtx.fillRect(0, 0, inverseCanvas.width, inverseCanvas.height);

        // Cut out the selected area (so selected area is NOT darkened)
        inverseCtx.globalCompositeOperation = 'destination-out';
        inverseCtx.drawImage(this.maskCanvas, 0, 0);

        // Draw the overlay on the main canvas
        ctx.drawImage(
            inverseCanvas,
            config.layer.x, config.layer.y,
            config.layer.width, config.layer.height
        );

        // Draw marching ants border around the actual mask contour
        if (this.edgeCanvas) {
            // Create a canvas for marching ants effect
            var antsCanvas = document.createElement('canvas');
            antsCanvas.width = this.maskCanvas.width;
            antsCanvas.height = this.maskCanvas.height;
            var antsCtx = antsCanvas.getContext('2d');

            // Draw the edge
            antsCtx.drawImage(this.edgeCanvas, 0, 0);

            // Apply marching ants color using composite
            antsCtx.globalCompositeOperation = 'source-in';

            // Alternate color based on animation offset
            var color = ((Math.floor(this.marchingAntsOffset / 4) % 2) === 0) ? '#00ff00' : '#ffffff';
            antsCtx.fillStyle = color;
            antsCtx.fillRect(0, 0, antsCanvas.width, antsCanvas.height);

            // Draw the marching ants outline
            ctx.drawImage(
                antsCanvas,
                config.layer.x, config.layer.y,
                config.layer.width, config.layer.height
            );
        }

        ctx.restore();
    }

    /**
     * Copy selected area to a new layer
     * The result preserves the mask shape with transparency
     */
    copyToLayer() {
        var _this = this;

        if (!this.currentMask || !this.maskCanvas) {
            alertify.error('No selection to copy');
            return;
        }

        var layer = config.layer;
        if (layer.type != 'image') {
            alertify.error('Layer must be an image');
            return;
        }

        // Get the bounds of the selection
        var bounds = this.selectionBounds;
        if (!bounds || bounds.origMinX === undefined) {
            alertify.error('Invalid selection bounds');
            return;
        }

        // Create canvas with just the selected pixels (masked)
        var maskedCanvas = document.createElement('canvas');
        maskedCanvas.width = layer.width_original;
        maskedCanvas.height = layer.height_original;
        var maskedCtx = maskedCanvas.getContext('2d');

        // Draw original image
        maskedCtx.drawImage(layer.link, 0, 0);

        // Apply mask - keep only selected pixels (this creates the shape!)
        maskedCtx.globalCompositeOperation = 'destination-in';
        maskedCtx.drawImage(this.maskCanvas, 0, 0);

        // Crop to selection bounds (still preserves transparency within the crop)
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

        // Copy only the selected region (transparency is preserved)
        croppedCtx.drawImage(
            maskedCanvas,
            bounds.origMinX, bounds.origMinY, cropWidth, cropHeight,
            0, 0, cropWidth, cropHeight
        );

        // Calculate position for new layer
        var scaleX = layer.width / layer.width_original;
        var scaleY = layer.height / layer.height_original;

        // Create new layer with the selection - use data as dataURL string
        var params = {
            x: Math.round(layer.x + bounds.origMinX * scaleX),
            y: Math.round(layer.y + bounds.origMinY * scaleY),
            width: Math.round(cropWidth * scaleX),
            height: Math.round(cropHeight * scaleY),
            width_original: cropWidth,
            height_original: cropHeight,
            type: 'image',
            name: config.layer.name + ' (Selection)',
            data: croppedCanvas.toDataURL('image/png')
        };

        app.State.do_action(
            new app.Actions.Bundle_action('copy_selection_to_layer', 'Copy Selection to Layer', [
                new app.Actions.Insert_layer_action(params)
            ])
        );

        // Enable transparency so the user can see the mask shape
        if (config.TRANSPARENCY == false) {
            config.TRANSPARENCY = true;
            _this.Base_layers.render();
        }

        alertify.success('Selection copied to new layer! Switch to Select tool to move it.');
    }

    /**
     * Cut selected area to a new layer (copy + delete from original)
     * The result preserves the mask shape with transparency
     */
    cutToLayer() {
        var _this = this;

        if (!this.currentMask || !this.maskCanvas) {
            alertify.error('No selection to cut');
            return;
        }

        var layer = config.layer;
        if (layer.type != 'image') {
            alertify.error('Layer must be an image');
            return;
        }

        // Get the bounds of the selection
        var bounds = this.selectionBounds;
        if (!bounds || bounds.origMinX === undefined) {
            alertify.error('Invalid selection bounds');
            return;
        }

        // Create canvas with just the selected pixels (masked)
        var maskedCanvas = document.createElement('canvas');
        maskedCanvas.width = layer.width_original;
        maskedCanvas.height = layer.height_original;
        var maskedCtx = maskedCanvas.getContext('2d');

        // Draw original image
        maskedCtx.drawImage(layer.link, 0, 0);

        // Apply mask - keep only selected pixels (this creates the shape!)
        maskedCtx.globalCompositeOperation = 'destination-in';
        maskedCtx.drawImage(this.maskCanvas, 0, 0);

        // Crop to selection bounds (still preserves transparency within the crop)
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

        // Copy only the selected region (transparency is preserved)
        croppedCtx.drawImage(
            maskedCanvas,
            bounds.origMinX, bounds.origMinY, cropWidth, cropHeight,
            0, 0, cropWidth, cropHeight
        );

        // Calculate position for new layer
        var scaleX = layer.width / layer.width_original;
        var scaleY = layer.height / layer.height_original;

        // Create params for new layer
        var params = {
            x: Math.round(layer.x + bounds.origMinX * scaleX),
            y: Math.round(layer.y + bounds.origMinY * scaleY),
            width: Math.round(cropWidth * scaleX),
            height: Math.round(cropHeight * scaleY),
            width_original: cropWidth,
            height_original: cropHeight,
            type: 'image',
            name: config.layer.name + ' (Cut)',
            data: croppedCanvas.toDataURL('image/png')
        };

        // Create canvas with hole where selection was
        var holeCanvas = document.createElement('canvas');
        holeCanvas.width = layer.width_original;
        holeCanvas.height = layer.height_original;
        var holeCtx = holeCanvas.getContext('2d');

        // Draw original image
        holeCtx.drawImage(layer.link, 0, 0);

        // Cut out the mask area (creates transparent hole in original shape)
        holeCtx.globalCompositeOperation = 'destination-out';
        holeCtx.drawImage(this.maskCanvas, 0, 0);

        // Execute both actions - update original layer, then insert new layer
        app.State.do_action(
            new app.Actions.Bundle_action('cut_selection_to_layer', 'Cut Selection to Layer', [
                new app.Actions.Update_layer_image_action(holeCanvas, layer.id),
                new app.Actions.Insert_layer_action(params)
            ])
        );

        // Enable transparency so the user can see the mask shape
        if (config.TRANSPARENCY == false) {
            config.TRANSPARENCY = true;
            _this.Base_layers.render();
        }

        // Clear the selection
        this.clearSelection();

        alertify.success('Selection cut to new layer! Switch to Select tool to move it.');
    }

    /**
     * Delete the selected area from the image
     */
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

        // Create canvas with hole where selection was
        var holeCanvas = document.createElement('canvas');
        holeCanvas.width = layer.width_original;
        holeCanvas.height = layer.height_original;
        var holeCtx = holeCanvas.getContext('2d');

        // Draw original image
        holeCtx.drawImage(layer.link, 0, 0);

        // Cut out the mask area
        holeCtx.globalCompositeOperation = 'destination-out';
        holeCtx.drawImage(this.maskCanvas, 0, 0);

        app.State.do_action(
            new app.Actions.Bundle_action('delete_selection', 'Delete Selection', [
                new app.Actions.Update_layer_image_action(holeCanvas, layer.id)
            ])
        );

        // Clear the selection
        this.clearSelection();

        alertify.success('Selection deleted!');
    }

    /**
     * Show the quick-action panel for the current selection.
     */
    _showActionPanel() {
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
     * Clear the current selection
     */
    clearSelection() {
        this.selectionActions.hide();
        this.currentMask = null;
        this.maskCanvas = null;
        this.edgeCanvas = null;
        this.selectionBounds = null;
        window.smartSelectMask = null;
        config.need_render = true;
        this.Base_layers.render();
    }

    on_leave() {
        this.selectionActions.hide();
        return [];
    }
}

export default Smart_select_class;
