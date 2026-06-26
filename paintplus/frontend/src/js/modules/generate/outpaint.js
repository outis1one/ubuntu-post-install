/**
 * Outpaint / Expand Canvas — remote provider fills the new region.
 * Menu target: generate/outpaint.outpaint
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../../services/api.js';
import { getCapabilities } from './../../api/capabilities.js';

var instance = null;

class Generate_outpaint_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.Base_layers = new Base_layers_class();
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
    }

    async outpaint() {
        var caps = await getCapabilities();
        if (!caps.remote || !caps.remote.healthy) {
            alertify.error(
                'Expand Canvas requires a remote AI provider. ' +
                'Set AI_PROVIDER (openai / invokeai / comfyui) in .env and restart.'
            );
            return;
        }

        var _this = this;

        this.Dialog.show({
            title: 'Expand Canvas (Outpaint)',
            params: [
                {
                    name: 'direction',
                    title: 'Expand direction:',
                    value: 'right',
                    values: ['right', 'left', 'bottom', 'top'],
                },
                {
                    name: 'size',
                    title: 'Pixels to add:',
                    type: 'range',
                    value: 256,
                    range: [64, 1024],
                    step: 64,
                },
                {
                    name: 'prompt',
                    title: 'Describe the expansion (optional):',
                    value: '',
                    placeholder: "e.g. 'continue the landscape', 'more sky and clouds'",
                },
            ],
            on_finish: async function (params) {
                await _this._run(params);
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
        alertify.message('Expanding canvas... please wait', 0);

        try {
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = config.layer.width_original;
            layerCanvas.height = config.layer.height_original;
            layerCanvas.getContext('2d').drawImage(config.layer.link, 0, 0);
            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];

            var response = await fetch(
                (window.API_BASE_URL || '') + '/api/generate/outpaint',
                {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        image: imageB64,
                        direction: params.direction,
                        size: params.size || 256,
                        prompt: params.prompt || '',
                    }),
                }
            );
            if (!response.ok) {
                var err = await response.json().catch(() => ({ detail: 'Unknown error' }));
                throw new Error(err.detail || 'Outpaint failed');
            }
            var result = await response.json();

            var img = new Image();
            img.onload = () => {
                var newW = img.naturalWidth;
                var newH = img.naturalHeight;
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = newW;
                resultCanvas.height = newH;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                // Update canvas dimensions and replace layer
                config.WIDTH  = newW;
                config.HEIGHT = newH;
                app.State.do_action(
                    new app.Actions.Bundle_action('outpaint', 'Expand Canvas', [
                        new app.Actions.Resize_canvas_action(newW, newH),
                        new app.Actions.Update_layer_image_action(resultCanvas),
                    ])
                );

                alertify.dismissAll();
                alertify.success('Canvas expanded!');
                this.isProcessing = false;
            };
            img.onerror = () => {
                alertify.dismissAll();
                alertify.error('Failed to load expanded image.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            alertify.dismissAll();
            alertify.error('Outpaint failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

export default Generate_outpaint_class;
