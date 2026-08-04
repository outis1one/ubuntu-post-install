/**
 * AI Smart Inpaint — paint a mask, enter a prompt, choose Fast (LaMa) or Quality (remote).
 *
 * Fast mode:  /api/erase   — LaMa local, no API key, seconds
 * Quality mode: /api/inpaint/remote — InvokeAI / ComfyUI / OpenAI, requires configured provider
 *
 * Registered as tool name: "ai_smart_inpaint"
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import Dialog_class from './../libs/popup.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../services/api.js';
import { getCapabilities } from './../api/capabilities.js';

class Ai_smart_inpaint_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.POP = new Dialog_class();
        this.ctx = ctx;
        this.name = 'ai_smart_inpaint';

        this.isDrawing = false;
        this.isProcessing = false;
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

    on_activate() {
        // Nothing on activate — tool is drag-to-paint, then dialog on mouseup
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
        this._paint(this.get_mouse_info(e));
    }

    mouseup(e) {
        if (!this.isDrawing) return;
        this.isDrawing = false;
        if (config.TOOL.name !== this.name) return;

        var maskData = this.maskCtx.getImageData(
            0, 0, this.maskCanvas.width, this.maskCanvas.height
        );
        if (!maskData.data.some((v, i) => i % 4 === 3 && v > 0)) return;

        this._showDialog();
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
        var lx = Math.round(this.adaptSize(Math.round(mouse.x) - config.layer.x, 'width'));
        var ly = Math.round(this.adaptSize(Math.round(mouse.y) - config.layer.y, 'height'));
        this.maskCtx.beginPath();
        this.maskCtx.arc(lx, ly, size / 2, 0, Math.PI * 2);
        this.maskCtx.fillStyle = '#ffffff';
        this.maskCtx.fill();
    }

    async _showDialog() {
        var caps = await getCapabilities();
        var hasRemote = caps.remote && caps.remote.healthy;

        var _this = this;

        var settings = {
            title: 'AI Smart Inpaint',
            params: [
                {
                    name: 'quality',
                    title: 'Mode:',
                    value: 'fast',
                    values: hasRemote ? ['fast', 'quality'] : ['fast'],
                    note: hasRemote ? 'Fast = LaMa (local). Quality = remote AI + prompt.' : 'Quality mode requires a remote provider (InvokeAI / ComfyUI / OpenAI).',
                },
                {
                    name: 'prompt',
                    title: 'What to put here (Quality mode only):',
                    type: 'textarea',
                    value: '',
                    placeholder: "e.g. 'lush green grass', 'wooden table surface', 'clear blue sky'",
                },
                {
                    name: 'negative_prompt',
                    title: 'Avoid (optional):',
                    value: '',
                    placeholder: 'blurry, distorted',
                },
            ],
            on_load: function (params, popup) {},
            on_finish: function (params) {
                _this._runInpaint(params.quality, params.prompt, params.negative_prompt);
            },
        };

        this.POP.show(settings);
    }

    async _runInpaint(quality, prompt, negativePrompt) {
        if (this.isProcessing) return;
        this.isProcessing = true;

        var modeLabel = quality === 'quality' ? 'Quality (remote)' : 'Fast (LaMa)';
        alertify.message('Inpainting (' + modeLabel + ')... please wait', 0);

        try {
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = config.layer.width_original;
            layerCanvas.height = config.layer.height_original;
            layerCanvas.getContext('2d').drawImage(config.layer.link, 0, 0);
            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];
            var maskB64  = this.maskCanvas.toDataURL('image/png').split(',')[1];

            var result;
            if (quality === 'quality') {
                result = await apiService.remoteInpaint(imageB64, maskB64, prompt || 'fill naturally', { negativePrompt });
            } else {
                result = await apiService.erase(imageB64, maskB64);
            }

            var img = new Image();
            img.onload = () => {
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = config.layer.width_original;
                resultCanvas.height = config.layer.height_original;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                app.State.do_action(
                    new app.Actions.Bundle_action('ai_smart_inpaint', 'AI Smart Inpaint', [
                        new app.Actions.Update_layer_image_action(resultCanvas)
                    ])
                );

                alertify.dismissAll();
                alertify.success('Done!');
                this.isProcessing = false;
            };
            img.onerror = () => {
                alertify.dismissAll();
                alertify.error('Failed to load result.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            alertify.dismissAll();
            alertify.error('Inpaint failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

export default Ai_smart_inpaint_class;
