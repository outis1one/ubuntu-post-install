/**
 * AI Replace Selection — pick any selection (Smart Select, Magic Wand, Lasso, Brush Select),
 * describe what should go there, remote provider fills it in.
 *
 * Requires a configured remote provider (InvokeAI / ComfyUI / OpenAI).
 * Registered as tool name: "ai_replace_selection"
 */

import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Dialog_class from './../libs/popup.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../services/api.js';
import { getCapabilities } from './../api/capabilities.js';

class Ai_replace_selection_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.POP = new Dialog_class();
        this.ctx = ctx;
        this.name = 'ai_replace_selection';
        this.isProcessing = false;
    }

    load() {}

    async on_activate() {
        var caps = await getCapabilities();
        if (!caps.remote || !caps.remote.healthy) {
            alertify.error(
                'Replace Selection requires a remote AI provider. ' +
                'Set AI_PROVIDER (openai / invokeai / comfyui) in .env and restart.'
            );
            return;
        }

        var hasMask = window.smartSelectMask?.canvas != null;
        var hasRect = this._getRectSelection() != null;

        if (!hasMask && !hasRect) {
            alertify.warning(
                'No selection found. Use Smart Select, Magic Wand, Lasso, ' +
                'Ellipse Select, or Brush Select first, then activate this tool.'
            );
            return;
        }

        this._showDialog(caps.remote.provider);
    }

    // ── Private ──────────────────────────────────────────────────────────────

    _getRectSelection() {
        if (!config.layer) return null;
        var sel = config.layer.selection;
        if (!sel) return null;
        var { x, y, width, height } = sel;
        if (!width || !height) return null;
        return { x, y, width, height };
    }

    _showDialog(providerName) {
        var _this = this;

        this.POP.show({
            title: 'AI Replace Selection',
            params: [
                {
                    name: 'prompt',
                    title: 'Describe what to place here:',
                    type: 'textarea',
                    value: '',
                    placeholder: "e.g. 'a blooming red rose', 'dark polished wood', 'a smiling golden retriever'",
                },
                {
                    name: 'negative_prompt',
                    title: 'Avoid (optional):',
                    value: '',
                    placeholder: 'blurry, distorted, low quality',
                },
                {
                    name: 'steps',
                    title: 'Steps:',
                    type: 'range',
                    value: 30,
                    range: [10, 60],
                    step: 5,
                },
                {
                    name: 'cfg_scale',
                    title: 'Prompt strength:',
                    type: 'range',
                    value: 75,
                    range: [10, 100],
                    step: 5,
                },
            ],
            on_finish: function (params) {
                if (!params.prompt || !params.prompt.trim()) {
                    alertify.warning('Please enter a description.');
                    return;
                }
                _this._run(params);
            },
        });
    }

    async _run(params) {
        if (this.isProcessing) return;
        if (config.layer.type !== 'image') {
            alertify.error('Current layer must be an image.');
            return;
        }

        this.isProcessing = true;
        alertify.message('Replacing selection... please wait', 0);

        try {
            // Build mask canvas from current selection
            var maskCanvas = await this._buildMaskCanvas();
            if (!maskCanvas) {
                alertify.dismissAll();
                alertify.error('Could not build selection mask.');
                this.isProcessing = false;
                return;
            }

            // Get layer as PNG
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = config.layer.width_original;
            layerCanvas.height = config.layer.height_original;
            layerCanvas.getContext('2d').drawImage(config.layer.link, 0, 0);

            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];
            var maskB64  = maskCanvas.toDataURL('image/png').split(',')[1];

            var result = await apiService.remoteInpaint(
                imageB64, maskB64,
                params.prompt,
                {
                    negativePrompt: params.negative_prompt || '',
                    steps: params.steps || 30,
                    cfgScale: (params.cfg_scale || 75) / 10,
                }
            );

            var img = new Image();
            img.onload = () => {
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = config.layer.width_original;
                resultCanvas.height = config.layer.height_original;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                app.State.do_action(
                    new app.Actions.Bundle_action('ai_replace_selection', 'AI Replace Selection', [
                        new app.Actions.Update_layer_image_action(resultCanvas)
                    ])
                );

                alertify.dismissAll();
                alertify.success('Done!');
                this.isProcessing = false;
            };
            img.onerror = () => {
                alertify.dismissAll();
                alertify.error('Failed to load result image.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            alertify.dismissAll();
            alertify.error('Replace failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }

    async _buildMaskCanvas() {
        var w = config.layer.width_original;
        var h = config.layer.height_original;
        var canvas = document.createElement('canvas');
        canvas.width  = w;
        canvas.height = h;
        var ctx = canvas.getContext('2d');

        // Prefer smartSelectMask (all selection tools write here)
        if (window.smartSelectMask?.canvas) {
            ctx.drawImage(window.smartSelectMask.canvas, 0, 0, w, h);
            // Ensure pure B&W
            var d = ctx.getImageData(0, 0, w, h);
            for (var i = 0; i < d.data.length; i += 4) {
                var v = d.data[i] > 128 ? 255 : 0;
                d.data[i] = d.data[i+1] = d.data[i+2] = v;
                d.data[i+3] = 255;
            }
            ctx.putImageData(d, 0, 0);
            return canvas;
        }

        // Fall back to rectangular selection
        var sel = this._getRectSelection();
        if (sel) {
            ctx.fillStyle = '#000';
            ctx.fillRect(0, 0, w, h);
            ctx.fillStyle = '#fff';
            ctx.fillRect(sel.x, sel.y, sel.width, sel.height);
            return canvas;
        }

        return null;
    }
}

export default Ai_replace_selection_class;
