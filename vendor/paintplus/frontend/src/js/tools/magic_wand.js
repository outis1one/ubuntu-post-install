/**
 * Magic Wand Selection Tool - Selects areas by color similarity
 * Click to select similar colors, Shift+Click to add to selection
 * Like GIMP's magic wand / fuzzy select tool
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';

class Magic_wand_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.ctx = ctx;
        this.name = 'magic_wand';

        // Store the current mask data
        this.currentMask = null;
        this.maskCanvas = null;
        this.selectionBounds = null;

        // Marching ants animation
        this.marchingAntsOffset = 0;

        // Edge canvas for drawing the mask outline
        this.edgeCanvas = null;
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

    mousedown(e) {
        var mouse = this.get_mouse_info(e);

        if (config.TOOL.name != this.name) return;
        if (mouse.click_valid == false) return;

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

        x = Math.round(x);
        y = Math.round(y);

        // Make sure click is within image bounds
        if (x < 0 || y < 0 || x >= config.layer.width_original || y >= config.layer.height_original) {
            alertify.error('Click inside the image');
            return;
        }

        // Check for Shift key - additive selection
        var isAdditive = e.shiftKey;

        // Get tool parameters
        var params = this.getParams();
        var tolerance = params.tolerance || 30;
        var contiguous = params.contiguous !== false;

        // Perform the selection
        this.selectByColor(x, y, tolerance, contiguous, isAdditive);
    }

    /**
     * Select pixels by color similarity using flood fill algorithm
     */
    selectByColor(startX, startY, tolerance, contiguous, isAdditive) {
        var layer = config.layer;

        // Get the layer's image data
        var srcCanvas = document.createElement('canvas');
        srcCanvas.width = layer.width_original;
        srcCanvas.height = layer.height_original;
        var srcCtx = srcCanvas.getContext('2d');
        srcCtx.drawImage(layer.link, 0, 0);

        var imageData = srcCtx.getImageData(0, 0, srcCanvas.width, srcCanvas.height);
        var data = imageData.data;
        var width = srcCanvas.width;
        var height = srcCanvas.height;

        // Create mask canvas
        var newMaskCanvas = document.createElement('canvas');
        newMaskCanvas.width = width;
        newMaskCanvas.height = height;
        var maskCtx = newMaskCanvas.getContext('2d');
        var maskImageData = maskCtx.createImageData(width, height);
        var maskData = maskImageData.data;

        // Get the color at the clicked point
        var startIdx = (startY * width + startX) * 4;
        var targetColor = {
            r: data[startIdx],
            g: data[startIdx + 1],
            b: data[startIdx + 2],
            a: data[startIdx + 3]
        };

        // Convert tolerance to 0-255 range
        var sens = tolerance * 255 / 100;

        if (contiguous) {
            // Flood fill - only connected pixels
            var visited = new Uint8Array(width * height);
            var stack = [[startX, startY]];
            var dx = [0, -1, +1, 0];
            var dy = [-1, 0, 0, +1];

            while (stack.length > 0) {
                var point = stack.pop();
                var px = point[0];
                var py = point[1];

                if (px < 0 || py < 0 || px >= width || py >= height) continue;

                var idx = py * width + px;
                if (visited[idx]) continue;
                visited[idx] = 1;

                var i = idx * 4;

                // Check color similarity
                if (Math.abs(data[i] - targetColor.r) <= sens &&
                    Math.abs(data[i + 1] - targetColor.g) <= sens &&
                    Math.abs(data[i + 2] - targetColor.b) <= sens &&
                    Math.abs(data[i + 3] - targetColor.a) <= sens) {

                    // Add to mask (white = selected)
                    maskData[i] = 255;
                    maskData[i + 1] = 255;
                    maskData[i + 2] = 255;
                    maskData[i + 3] = 255;

                    // Add neighbors to stack
                    for (var d = 0; d < 4; d++) {
                        stack.push([px + dx[d], py + dy[d]]);
                    }
                }
            }
        } else {
            // Global - all matching pixels regardless of connection
            for (var y = 0; y < height; y++) {
                for (var x = 0; x < width; x++) {
                    var i = (y * width + x) * 4;

                    if (Math.abs(data[i] - targetColor.r) <= sens &&
                        Math.abs(data[i + 1] - targetColor.g) <= sens &&
                        Math.abs(data[i + 2] - targetColor.b) <= sens &&
                        Math.abs(data[i + 3] - targetColor.a) <= sens) {

                        maskData[i] = 255;
                        maskData[i + 1] = 255;
                        maskData[i + 2] = 255;
                        maskData[i + 3] = 255;
                    }
                }
            }
        }

        maskCtx.putImageData(maskImageData, 0, 0);

        // If additive and we have an existing mask, combine them
        if (isAdditive && this.maskCanvas) {
            var combinedCanvas = document.createElement('canvas');
            combinedCanvas.width = width;
            combinedCanvas.height = height;
            var combinedCtx = combinedCanvas.getContext('2d');

            // Draw existing mask
            combinedCtx.drawImage(this.maskCanvas, 0, 0);

            // Add new mask
            combinedCtx.globalCompositeOperation = 'lighter';
            combinedCtx.drawImage(newMaskCanvas, 0, 0);

            this.maskCanvas = combinedCanvas;
        } else {
            this.maskCanvas = newMaskCanvas;
        }

        this.currentMask = {
            canvas: this.maskCanvas
        };

        // Store globally for other tools
        window.smartSelectMask = this.currentMask;

        // Calculate bounds and extract edge
        this.calculateSelectionBounds();
        this.extractContourPath();

        config.need_render = true;
        this.Base_layers.render();

        if (isAdditive) {
            alertify.success('Added to selection!');
        } else {
            alertify.success('Selection complete! Shift+Click to add more.');
        }
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

            var color = ((Math.floor(this.marchingAntsOffset / 4) % 2) === 0) ? '#ff00ff' : '#ffffff';
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

        var canvas = document.createElement('canvas');
        canvas.width = layer.width_original;
        canvas.height = layer.height_original;
        var ctx = canvas.getContext('2d');

        ctx.drawImage(layer.link, 0, 0);
        ctx.globalCompositeOperation = 'destination-in';
        ctx.drawImage(this.maskCanvas, 0, 0);

        var cropWidth = bounds.origMaxX - bounds.origMinX;
        var cropHeight = bounds.origMaxY - bounds.origMinY;

        if (cropWidth <= 0 || cropHeight <= 0) {
            alertify.error('Selection is too small');
            return;
        }

        var croppedCanvas = document.createElement('canvas');
        croppedCanvas.width = cropWidth;
        croppedCanvas.height = cropHeight;
        var croppedCtx = croppedCanvas.getContext('2d');

        croppedCtx.drawImage(
            canvas,
            bounds.origMinX, bounds.origMinY, cropWidth, cropHeight,
            0, 0, cropWidth, cropHeight
        );

        var scaleX = layer.width / layer.width_original;
        var scaleY = layer.height / layer.height_original;

        var params = {
            x: Math.round(layer.x + bounds.origMinX * scaleX),
            y: Math.round(layer.y + bounds.origMinY * scaleY),
            width: cropWidth,
            height: cropHeight,
            width_original: cropWidth,
            height_original: cropHeight,
            type: 'image',
            name: 'Magic Wand Selection',
            data: croppedCanvas.toDataURL('image/png')
        };

        app.State.do_action(
            new app.Actions.Bundle_action('copy_selection_to_layer', 'Copy Selection to Layer', [
                new app.Actions.Insert_layer_action(params)
            ])
        );

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

        var canvas = document.createElement('canvas');
        canvas.width = layer.width_original;
        canvas.height = layer.height_original;
        var ctx = canvas.getContext('2d');

        ctx.drawImage(layer.link, 0, 0);
        ctx.globalCompositeOperation = 'destination-in';
        ctx.drawImage(this.maskCanvas, 0, 0);

        var cropWidth = bounds.origMaxX - bounds.origMinX;
        var cropHeight = bounds.origMaxY - bounds.origMinY;

        if (cropWidth <= 0 || cropHeight <= 0) {
            alertify.error('Selection is too small');
            return;
        }

        var croppedCanvas = document.createElement('canvas');
        croppedCanvas.width = cropWidth;
        croppedCanvas.height = cropHeight;
        var croppedCtx = croppedCanvas.getContext('2d');

        croppedCtx.drawImage(
            canvas,
            bounds.origMinX, bounds.origMinY, cropWidth, cropHeight,
            0, 0, cropWidth, cropHeight
        );

        var scaleX = layer.width / layer.width_original;
        var scaleY = layer.height / layer.height_original;

        var params = {
            x: Math.round(layer.x + bounds.origMinX * scaleX),
            y: Math.round(layer.y + bounds.origMinY * scaleY),
            width: cropWidth,
            height: cropHeight,
            width_original: cropWidth,
            height_original: cropHeight,
            type: 'image',
            name: 'Magic Wand Cut',
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
        this.currentMask = null;
        this.maskCanvas = null;
        this.edgeCanvas = null;
        this.selectionBounds = null;
        window.smartSelectMask = null;
        config.need_render = true;
        this.Base_layers.render();
    }

    on_leave() {
        return [];
    }
}

export default Magic_wand_class;
