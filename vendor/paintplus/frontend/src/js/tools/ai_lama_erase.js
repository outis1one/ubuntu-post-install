/**
 * AI Magic Eraser — paint a mask with a brush, send to LaMa backend, apply result.
 * Works locally (no API key). GPU auto-detected; CPU fallback always available.
 *
 * Workflow:
 *   1. User paints over the object to erase (red overlay shows the mask)
 *   2. On mouseup, POST image + mask to /api/erase
 *   3. Result replaces the current layer canvas
 *
 * Registered as tool name: "ai_lama_erase"
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../services/api.js';

class Ai_lama_erase_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.ctx = ctx;
        this.name = 'ai_lama_erase';

        this.isDrawing = false;
        this.isProcessing = false;

        // Off-screen canvas used to accumulate the painted mask
        this.maskCanvas = null;
        this.maskCtx = null;
    }

    load() {
        var _this = this;
        document.addEventListener('mousedown', function (e) { _this.mousedown(e); });
        document.addEventListener('mousemove', function (e) { _this.mousemove(e); });
        document.addEventListener('mouseup',   function (e) { _this.mouseup(e); });
        document.addEventListener('touchstart', function (e) { _this.mousedown(e); }, { passive: false });
        document.addEventListener('touchmove',  function (e) { _this.mousemove(e); }, { passive: false });
        document.addEventListener('touchend',   function (e) { _this.mouseup(e); });
    }

    mousedown(e) {
        var mouse = this.get_mouse_info(e);
        if (!mouse.click_valid) return;
        if (config.TOOL.name !== this.name) return;
        if (this.isProcessing) return;

        if (config.layer.type !== 'image') {
            alertify.error('This layer must contain an image.');
            return;
        }

        this._initMask();
        this.isDrawing = true;
        this._paint(mouse);
    }

    mousemove(e) {
        if (!this.isDrawing) return;
        if (config.TOOL.name !== this.name) return;
        var mouse = this.get_mouse_info(e);
        this._paint(mouse);
    }

    mouseup(e) {
        if (!this.isDrawing) return;
        this.isDrawing = false;
        if (config.TOOL.name !== this.name) return;
        this._applyErase();
    }

    // ── Private ──────────────────────────────────────────────────────────────

    _initMask() {
        var w = config.layer.width_original;
        var h = config.layer.height_original;

        if (!this.maskCanvas || this.maskCanvas.width !== w || this.maskCanvas.height !== h) {
            this.maskCanvas = document.createElement('canvas');
            this.maskCanvas.width = w;
            this.maskCanvas.height = h;
            this.maskCtx = this.maskCanvas.getContext('2d');
        }
        this.maskCtx.clearRect(0, 0, w, h);
    }

    _paint(mouse) {
        var params = this.getParams();
        var size = params.size || 30;

        // Map screen coords → layer-original coords
        var lx = Math.round(this.adaptSize(Math.round(mouse.x) - config.layer.x, 'width'));
        var ly = Math.round(this.adaptSize(Math.round(mouse.y) - config.layer.y, 'height'));

        this.maskCtx.beginPath();
        this.maskCtx.arc(lx, ly, size / 2, 0, Math.PI * 2);
        this.maskCtx.fillStyle = '#ffffff';
        this.maskCtx.fill();

        // Show red overlay on screen so user can see the painted area
        this._renderOverlay(lx, ly, size);
    }

    _renderOverlay(lx, ly, size) {
        // Draw a translucent red circle on the main canvas for visual feedback
        var scale = config.ZOOM / 100;
        var sx = config.layer.x * scale + lx * scale;
        var sy = config.layer.y * scale + ly * scale;
        var sRadius = (size / 2) * scale;

        var mainCtx = document.getElementById('canvas_temp')
            ? document.getElementById('canvas_temp').getContext('2d')
            : null;
        if (!mainCtx) return;

        mainCtx.save();
        mainCtx.beginPath();
        mainCtx.arc(sx, sy, sRadius, 0, Math.PI * 2);
        mainCtx.fillStyle = 'rgba(255, 60, 60, 0.4)';
        mainCtx.fill();
        mainCtx.restore();
    }

    async _applyErase() {
        if (this.isProcessing) return;

        // Check if any mask pixels were painted
        var maskData = this.maskCtx.getImageData(
            0, 0, this.maskCanvas.width, this.maskCanvas.height
        );
        var hasPixels = maskData.data.some((v, i) => i % 4 === 3 && v > 0);
        if (!hasPixels) return;

        this.isProcessing = true;
        alertify.message('AI erasing... please wait', 0);

        try {
            // Get current layer as PNG base64
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = config.layer.width_original;
            layerCanvas.height = config.layer.height_original;
            var lctx = layerCanvas.getContext('2d');
            lctx.drawImage(config.layer.link, 0, 0);
            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];

            // Get mask as PNG base64
            var maskB64 = this.maskCanvas.toDataURL('image/png').split(',')[1];

            // Call backend
            var result = await apiService.erase(imageB64, maskB64);

            // Apply result back to layer
            var img = new Image();
            img.onload = () => {
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = config.layer.width_original;
                resultCanvas.height = config.layer.height_original;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                app.State.do_action(
                    new app.Actions.Bundle_action('ai_lama_erase', 'AI Erase', [
                        new app.Actions.Update_layer_image_action(resultCanvas)
                    ])
                );

                alertify.dismissAll();
                alertify.success('Erased! (' + result.method + ')');
                this.isProcessing = false;
                this._clearOverlay();
            };
            img.onerror = () => {
                alertify.dismissAll();
                alertify.error('Failed to load result image.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            alertify.dismissAll();
            alertify.error('AI erase failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }

    _clearOverlay() {
        var canvas = document.getElementById('canvas_temp');
        if (canvas) {
            canvas.getContext('2d').clearRect(0, 0, canvas.width, canvas.height);
        }
    }
}

export default Ai_lama_erase_class;
