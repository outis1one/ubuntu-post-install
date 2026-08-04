/**
 * Ellipse Selection Tool - Draw elliptical/circular selections
 * Drag to create ellipse selection, Shift+Drag for perfect circle
 * Hold Alt to draw from center
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';

class Ellipse_select_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.ctx = ctx;
        this.name = 'ellipse_select';

        // Drawing state
        this.isDrawing = false;
        this.startPoint = null;
        this.currentPoint = null;
        this.isAdditive = false;
        this.isCircle = false;
        this.fromCenter = false;

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

            if (code == 46 && _this.currentMask) {
                e.preventDefault();
                _this.deleteSelection();
            }
            if (code == 27 && _this.currentMask) {
                e.preventDefault();
                _this.clearSelection();
            }
            if (code == 67 && (e.ctrlKey || e.metaKey) && _this.currentMask) {
                e.preventDefault();
                _this.copyToLayer();
            }
            if (code == 88 && (e.ctrlKey || e.metaKey) && _this.currentMask) {
                e.preventDefault();
                _this.cutToLayer();
            }
        });

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

        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer first');
            return;
        }

        this.isDrawing = true;
        this.isAdditive = e.shiftKey;
        this.isCircle = false;
        this.fromCenter = e.altKey;

        this.startPoint = this.getImagePoint(mouse.x, mouse.y);
        this.currentPoint = this.startPoint;

        config.need_render = true;
    }

    mousemove(e) {
        if (!this.isDrawing) return;
        if (config.TOOL.name != this.name) return;

        var mouse = this.get_mouse_info(e);

        this.currentPoint = this.getImagePoint(mouse.x, mouse.y);
        this.isCircle = e.shiftKey;
        this.fromCenter = e.altKey;

        config.need_render = true;
    }

    mouseup(e) {
        if (!this.isDrawing) return;
        if (config.TOOL.name != this.name) return;

        this.isDrawing = false;

        var mouse = this.get_mouse_info(e);
        this.currentPoint = this.getImagePoint(mouse.x, mouse.y);
        this.isCircle = e.shiftKey;
        this.fromCenter = e.altKey;

        // Calculate ellipse bounds
        var ellipse = this.calculateEllipse();

        if (ellipse.radiusX < 2 || ellipse.radiusY < 2) {
            alertify.warning('Draw a larger selection');
            config.need_render = true;
            return;
        }

        // Create mask from ellipse
        this.createMaskFromEllipse(ellipse, this.isAdditive);

        this.startPoint = null;
        this.currentPoint = null;
    }

    getImagePoint(mouseX, mouseY) {
        var x = mouseX - config.layer.x;
        var y = mouseY - config.layer.y;

        if (config.layer.width != config.layer.width_original) {
            x = x * (config.layer.width_original / config.layer.width);
        }
        if (config.layer.height != config.layer.height_original) {
            y = y * (config.layer.height_original / config.layer.height);
        }

        x = Math.max(0, Math.min(config.layer.width_original - 1, Math.round(x)));
        y = Math.max(0, Math.min(config.layer.height_original - 1, Math.round(y)));

        return { x: x, y: y };
    }

    calculateEllipse() {
        if (!this.startPoint || !this.currentPoint) {
            return { centerX: 0, centerY: 0, radiusX: 0, radiusY: 0 };
        }

        var x1 = this.startPoint.x;
        var y1 = this.startPoint.y;
        var x2 = this.currentPoint.x;
        var y2 = this.currentPoint.y;

        var width = Math.abs(x2 - x1);
        var height = Math.abs(y2 - y1);

        // If Shift is held, make it a circle (equal radii)
        if (this.isCircle) {
            var maxDim = Math.max(width, height);
            width = maxDim;
            height = maxDim;
        }

        var centerX, centerY, radiusX, radiusY;

        if (this.fromCenter) {
            // Draw from center
            centerX = x1;
            centerY = y1;
            radiusX = width;
            radiusY = height;
        } else {
            // Draw from corner
            var left = Math.min(x1, x2);
            var top = Math.min(y1, y2);

            if (this.isCircle) {
                // Adjust for circle from corner
                if (x2 < x1) left = x1 - width;
                if (y2 < y1) top = y1 - height;
            }

            centerX = left + width / 2;
            centerY = top + height / 2;
            radiusX = width / 2;
            radiusY = height / 2;
        }

        return {
            centerX: centerX,
            centerY: centerY,
            radiusX: radiusX,
            radiusY: radiusY
        };
    }

    createMaskFromEllipse(ellipse, isAdditive) {
        var width = config.layer.width_original;
        var height = config.layer.height_original;

        var newMaskCanvas = document.createElement('canvas');
        newMaskCanvas.width = width;
        newMaskCanvas.height = height;
        var maskCtx = newMaskCanvas.getContext('2d');

        // Draw filled ellipse
        maskCtx.fillStyle = 'white';
        maskCtx.beginPath();
        maskCtx.ellipse(
            ellipse.centerX,
            ellipse.centerY,
            ellipse.radiusX,
            ellipse.radiusY,
            0, 0, Math.PI * 2
        );
        maskCtx.fill();

        // Combine with existing mask if additive
        if (isAdditive && this.maskCanvas) {
            var combinedCanvas = document.createElement('canvas');
            combinedCanvas.width = width;
            combinedCanvas.height = height;
            var combinedCtx = combinedCanvas.getContext('2d');

            combinedCtx.drawImage(this.maskCanvas, 0, 0);
            combinedCtx.globalCompositeOperation = 'lighter';
            combinedCtx.drawImage(newMaskCanvas, 0, 0);

            this.maskCanvas = combinedCanvas;
        } else {
            this.maskCanvas = newMaskCanvas;
        }

        this.currentMask = {
            canvas: this.maskCanvas
        };

        window.smartSelectMask = this.currentMask;

        this.calculateSelectionBounds();
        this.extractContourPath();

        config.need_render = true;
        this.Base_layers.render();

        if (isAdditive) {
            alertify.success('Added to selection!');
        } else {
            alertify.success('Selection complete! Hold Shift while dragging to add more.');
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
        // Draw current ellipse being drawn
        if (this.isDrawing && this.startPoint && this.currentPoint) {
            ctx.save();

            var ellipse = this.calculateEllipse();
            var scaleX = config.layer.width / config.layer.width_original;
            var scaleY = config.layer.height / config.layer.height_original;

            ctx.strokeStyle = '#ffff00';
            ctx.lineWidth = 2 / config.ZOOM;
            ctx.setLineDash([5, 5]);
            ctx.lineDashOffset = -this.marchingAntsOffset;

            ctx.beginPath();
            ctx.ellipse(
                config.layer.x + ellipse.centerX * scaleX,
                config.layer.y + ellipse.centerY * scaleY,
                ellipse.radiusX * scaleX,
                ellipse.radiusY * scaleY,
                0, 0, Math.PI * 2
            );
            ctx.stroke();

            ctx.restore();
        }

        // Draw existing selection
        if (!this.currentMask || !this.maskCanvas) return;

        ctx.save();

        // Draw semi-transparent overlay
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

            var color = ((Math.floor(this.marchingAntsOffset / 4) % 2) === 0) ? '#ffff00' : '#ffffff';
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
            name: 'Ellipse Selection',
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
            name: 'Ellipse Cut',
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
        this.startPoint = null;
        this.currentPoint = null;
        window.smartSelectMask = null;
        config.need_render = true;
        this.Base_layers.render();
    }

    on_leave() {
        this.isDrawing = false;
        this.startPoint = null;
        this.currentPoint = null;
        return [];
    }
}

export default Ellipse_select_class;
