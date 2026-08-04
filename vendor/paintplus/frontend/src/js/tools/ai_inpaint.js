/**
 * AI Inpaint Tool - Edit selected regions using AI with text prompts
 * Works with any selection tool: Smart Select, Magic Wand, Lasso, Ellipse Select, or Selection
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import Dialog_class from './../libs/popup.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../services/api.js';

class Ai_inpaint_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.POP = new Dialog_class();
        this.ctx = ctx;
        this.name = 'ai_inpaint';
        this.isProcessing = false;
    }

    load() {
        // No mouse events needed - this tool uses a dialog
    }

    on_activate() {
        this.showInpaintDialog();
    }

    /**
     * Show the inpainting dialog
     */
    showInpaintDialog() {
        var _this = this;

        // Check if we have a selection from any selection tool
        // All selection tools (Smart Select, Magic Wand, Lasso, Ellipse Select) store their mask in window.smartSelectMask
        var hasMask = window.smartSelectMask != null && window.smartSelectMask.canvas != null;
        var hasRectSelection = this.getRectSelection() != null;

        if (!hasMask && !hasRectSelection) {
            alertify.warning('No selection found. Use Smart Select, Magic Wand, Lasso, Ellipse Select, or Selection tool first.');
            return;
        }

        var settings = {
            title: 'AI Edit Selection',
            params: [
                {
                    name: "mode",
                    title: "Edit Mode:",
                    value: "inpaint",
                    values: ["inpaint", "transform"]
                },
                {
                    name: "prompt",
                    title: "AI Inpaint - Describe replacement:",
                    type: "textarea",
                    value: "",
                    placeholder: "AI will REPLACE the selection with what you describe.\nExamples: 'a red rose', 'empty background', 'blue sky'"
                },
                {
                    name: "negative_prompt",
                    title: "What to avoid (optional):",
                    value: "",
                    placeholder: "e.g., 'blurry, distorted, low quality'"
                },
                {
                    name: "strength",
                    title: "AI Edit Strength:",
                    type: "range",
                    value: 80,
                    range: [1, 100],
                    step: 1
                },
                {
                    name: "scale",
                    title: "Transform - Scale %:",
                    type: "range",
                    value: 100,
                    range: [10, 200],
                    step: 5
                }
            ],
            on_load: function(el) {
                // Add info text
                var infoDiv = document.createElement('div');
                infoDiv.className = 'ai-inpaint-info';
                infoDiv.innerHTML = '<p style="font-size:12px;color:#aaa;margin-bottom:10px;">' +
                    '<strong>Inpaint Mode:</strong> AI replaces the selected area with generated content.<br>' +
                    '<strong>Transform Mode:</strong> Scale, shrink, or enlarge the selection without AI.<br>' +
                    '<em>Tip: To shrink something by 35%, use Transform mode with Scale at 65%.</em></p>';

                var dialogContent = el.querySelector('.dialog_content');
                if (dialogContent && dialogContent.firstChild) {
                    dialogContent.insertBefore(infoDiv, dialogContent.firstChild);
                }
            },
            on_finish: async function (params) {
                if (params.mode === 'transform') {
                    await _this.executeTransform(params);
                } else {
                    await _this.executeInpaint(params);
                }
            },
        };

        this.POP.show(settings);
    }

    /**
     * Execute transform operation (scale without AI)
     */
    async executeTransform(params) {
        if (this.isProcessing) {
            alertify.warning('Already processing... please wait');
            return;
        }

        // Check if we have an image layer
        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer');
            return;
        }

        var maskCanvas = window.smartSelectMask?.canvas;
        if (!maskCanvas) {
            alertify.error('No selection mask found');
            return;
        }

        this.isProcessing = true;
        alertify.message('Transforming selection...');

        try {
            var layer = config.layer;
            var scale = params.scale / 100;

            // Get mask bounds
            var maskCtx = maskCanvas.getContext('2d');
            var imageData = maskCtx.getImageData(0, 0, maskCanvas.width, maskCanvas.height);
            var minX = maskCanvas.width, minY = maskCanvas.height;
            var maxX = 0, maxY = 0;

            for (var y = 0; y < maskCanvas.height; y++) {
                for (var x = 0; x < maskCanvas.width; x++) {
                    var i = (y * maskCanvas.width + x) * 4;
                    if (imageData.data[i] > 128) {
                        minX = Math.min(minX, x);
                        minY = Math.min(minY, y);
                        maxX = Math.max(maxX, x);
                        maxY = Math.max(maxY, y);
                    }
                }
            }

            if (maxX <= minX || maxY <= minY) {
                throw new Error('Selection is too small');
            }

            var selWidth = maxX - minX + 1;
            var selHeight = maxY - minY + 1;
            var centerX = minX + selWidth / 2;
            var centerY = minY + selHeight / 2;

            // Extract selected pixels
            var extractCanvas = document.createElement('canvas');
            extractCanvas.width = layer.width_original;
            extractCanvas.height = layer.height_original;
            var extractCtx = extractCanvas.getContext('2d');
            extractCtx.drawImage(layer.link, 0, 0);
            extractCtx.globalCompositeOperation = 'destination-in';
            extractCtx.drawImage(maskCanvas, 0, 0);

            // Create result canvas
            var resultCanvas = document.createElement('canvas');
            resultCanvas.width = layer.width_original;
            resultCanvas.height = layer.height_original;
            var resultCtx = resultCanvas.getContext('2d');

            // Draw original image
            resultCtx.drawImage(layer.link, 0, 0);

            // Remove original selection (create hole)
            resultCtx.globalCompositeOperation = 'destination-out';
            resultCtx.drawImage(maskCanvas, 0, 0);

            // Calculate scaled dimensions
            var newWidth = selWidth * scale;
            var newHeight = selHeight * scale;
            var newX = centerX - newWidth / 2;
            var newY = centerY - newHeight / 2;

            // Draw scaled selection back
            resultCtx.globalCompositeOperation = 'source-over';

            // Create temp canvas for just the selection
            var selCanvas = document.createElement('canvas');
            selCanvas.width = selWidth;
            selCanvas.height = selHeight;
            var selCtx = selCanvas.getContext('2d');
            selCtx.drawImage(extractCanvas, minX, minY, selWidth, selHeight, 0, 0, selWidth, selHeight);

            // Draw scaled
            resultCtx.drawImage(selCanvas, 0, 0, selWidth, selHeight, newX, newY, newWidth, newHeight);

            // Apply result
            app.State.do_action(
                new app.Actions.Bundle_action('transform_selection', 'Transform Selection', [
                    new app.Actions.Update_layer_image_action(resultCanvas)
                ])
            );

            // Clear selection
            window.smartSelectMask = null;
            config.need_render = true;

            alertify.success('Transform complete! Selection scaled to ' + params.scale + '%');

        } catch (error) {
            console.error('Transform error:', error);
            alertify.error('Transform failed: ' + error.message);
        } finally {
            this.isProcessing = false;
        }
    }

    /**
     * Execute the inpainting operation
     */
    async executeInpaint(params) {
        if (this.isProcessing) {
            alertify.warning('Already processing... please wait');
            return;
        }

        if (!params.prompt || params.prompt.trim() === '') {
            alertify.error('Please enter a prompt describing what you want');
            return;
        }

        // Check if we have an image layer
        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer');
            return;
        }

        this.isProcessing = true;
        alertify.message('AI is generating... this may take a moment');

        try {
            // Get image data
            var imageData = this.getLayerImageData();

            // Get mask data (from Smart Select or rectangular selection)
            var maskData = this.getMaskData();

            if (!maskData) {
                throw new Error('No valid selection/mask found');
            }

            // Call inpaint API
            var result = await apiService.inpaint(
                imageData,
                maskData,
                params.prompt,
                {
                    negativePrompt: params.negative_prompt || '',
                    strength: params.strength / 100
                }
            );

            // Apply result to layer
            await this.applyResult(result.result);

            alertify.success('Inpainting complete!');

        } catch (error) {
            console.error('Inpaint error:', error);
            alertify.error('Inpainting failed: ' + error.message);
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
        ctx.drawImage(config.layer.link, 0, 0);

        return canvas.toDataURL('image/png').split(',')[1];
    }

    /**
     * Get mask data - either from Smart Select or rectangular selection
     */
    getMaskData() {
        // First try Smart Select mask
        if (window.smartSelectMask && window.smartSelectMask.canvas) {
            var maskCanvas = window.smartSelectMask.canvas;
            return maskCanvas.toDataURL('image/png').split(',')[1];
        }

        // Fall back to rectangular selection
        var selection = this.getRectSelection();
        if (selection) {
            return this.createRectMask(selection);
        }

        return null;
    }

    /**
     * Get rectangular selection from miniPaint's selection tool
     */
    getRectSelection() {
        // Try to get selection from selection tool
        var Selection = null;
        try {
            var GUI_tools = app.GUI?.GUI_tools || this.Base_layers?.Base_gui?.GUI_tools;
            if (GUI_tools && GUI_tools.tools_modules && GUI_tools.tools_modules.selection) {
                Selection = GUI_tools.tools_modules.selection.object;
            }
        } catch (e) {
            // Selection tool not available
        }

        if (Selection && Selection.selection &&
            Selection.selection.width > 0 && Selection.selection.height > 0) {
            return Selection.selection;
        }

        return null;
    }

    /**
     * Create a white rectangle mask from selection coordinates
     */
    createRectMask(selection) {
        var canvas = document.createElement('canvas');
        var ctx = canvas.getContext('2d');

        canvas.width = config.layer.width_original;
        canvas.height = config.layer.height_original;

        // Fill with black (unselected)
        ctx.fillStyle = '#000000';
        ctx.fillRect(0, 0, canvas.width, canvas.height);

        // Calculate selection position relative to layer
        var x = selection.x - config.layer.x;
        var y = selection.y - config.layer.y;
        var width = selection.width;
        var height = selection.height;

        // Scale to original image size
        var scaleX = config.layer.width_original / config.layer.width;
        var scaleY = config.layer.height_original / config.layer.height;

        x = x * scaleX;
        y = y * scaleY;
        width = width * scaleX;
        height = height * scaleY;

        // Draw white rectangle (selected area)
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(x, y, width, height);

        return canvas.toDataURL('image/png').split(',')[1];
    }

    /**
     * Apply the inpainted result to the current layer
     */
    async applyResult(resultBase64) {
        var _this = this;

        return new Promise((resolve, reject) => {
            var img = new Image();
            img.onload = function() {
                // Create canvas with result
                var canvas = document.createElement('canvas');
                canvas.width = config.layer.width_original;
                canvas.height = config.layer.height_original;
                var ctx = canvas.getContext('2d');
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

                // Update layer through action system for undo support
                app.State.do_action(
                    new app.Actions.Bundle_action('ai_inpaint', 'AI Inpaint', [
                        new app.Actions.Update_layer_image_action(canvas)
                    ])
                );

                // Clear the smart select mask
                window.smartSelectMask = null;

                config.need_render = true;
                resolve();
            };
            img.onerror = function() {
                reject(new Error('Failed to load result image'));
            };
            img.src = 'data:image/png;base64,' + resultBase64;
        });
    }

    render_overlay(ctx) {
        // Show visual indicator if there's a selection ready for inpainting
        if (window.smartSelectMask && window.smartSelectMask.canvas) {
            // Draw a subtle border around the tool indicating mask is ready
            ctx.save();
            ctx.strokeStyle = '#00ff00';
            ctx.lineWidth = 2;
            ctx.setLineDash([5, 5]);

            var scaleX = config.layer.width / config.layer.width_original;
            var scaleY = config.layer.height / config.layer.height_original;

            // Get mask bounds
            var maskCanvas = window.smartSelectMask.canvas;
            var maskCtx = maskCanvas.getContext('2d');
            var imageData = maskCtx.getImageData(0, 0, maskCanvas.width, maskCanvas.height);

            var minX = maskCanvas.width, minY = maskCanvas.height;
            var maxX = 0, maxY = 0;

            for (var y = 0; y < maskCanvas.height; y += 4) { // Sample every 4th pixel for speed
                for (var x = 0; x < maskCanvas.width; x += 4) {
                    var i = (y * maskCanvas.width + x) * 4;
                    if (imageData.data[i] > 128) {
                        minX = Math.min(minX, x);
                        minY = Math.min(minY, y);
                        maxX = Math.max(maxX, x);
                        maxY = Math.max(maxY, y);
                    }
                }
            }

            if (maxX > minX && maxY > minY) {
                ctx.strokeRect(
                    config.layer.x + minX * scaleX,
                    config.layer.y + minY * scaleY,
                    (maxX - minX) * scaleX,
                    (maxY - minY) * scaleY
                );
            }

            ctx.restore();
        }
    }
}

export default Ai_inpaint_class;
