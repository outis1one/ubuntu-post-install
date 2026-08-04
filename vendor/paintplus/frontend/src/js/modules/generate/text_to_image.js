/**
 * Text → Image — generates via remote or local-GPU provider,
 * pastes result as a new layer on the current canvas.
 *
 * Menu target: generate/text_to_image.text_to_image
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../../services/api.js';
import { getCapabilities } from './../../api/capabilities.js';
import { showProgress, updateProgress, hideProgress, connectProgressSSE, disconnectProgressSSE } from './../../libs/progress_overlay.js';

var instance = null;

class Generate_text_to_image_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.Base_layers = new Base_layers_class();
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
    }

    async text_to_image() {
        var caps = await getCapabilities();
        var hasRemote = caps.remote && caps.remote.healthy;
        var hasLocal  = caps.local  && caps.local.local_gpu_available;

        if (!hasRemote && !hasLocal) {
            alertify.error(
                'Text → Image requires an AI provider. ' +
                'Set AI_PROVIDER=openai / invokeai / comfyui / local_gpu in .env and restart, ' +
                'or configure one in Image → AI Provider Settings.'
            );
            return;
        }

        var _this  = this;
        var canvasW = config.WIDTH  || 1024;
        var canvasH = config.HEIGHT || 1024;

        // Build provider info line
        var providerHtml = hasRemote
            ? `<span style="color:#44cc44">● ${caps.remote.provider}</span>`
            : `<span style="color:#44cc44">● local GPU · ${caps.local.gpu_tier || ''} · ${_shortGpu(caps.local.gpu_device)}</span>`;

        // Model note for local GPU
        var modelNote = '';
        if (hasLocal && !hasRemote) {
            var rec = caps.local.local_gpu_capabilities && caps.local.local_gpu_capabilities.recommended;
            var m = rec && rec.txt2img;
            if (m) {
                modelNote = `Model: <span style="color:#ddd">${m.model_id.split('/').pop()}</span>`;
                if (m.memory_opt && m.memory_opt !== 'none') modelNote += ` · <span style="color:#aaa">${m.memory_opt}</span>`;
            }
        }

        // Estimate generation time (rough guide for the progress bar)
        var estSec = hasLocal ? 60 : 15;  // local GPU ~1 min; OpenAI ~15s

        var defaultW = Math.min(canvasW, hasLocal ? (caps.local.local_gpu_capabilities?.recommended?.txt2img?.native_res || 1024) : 1024);
        var defaultH = Math.min(canvasH, defaultW);

        this.Dialog.show({
            title: 'Text → Image',
            params: [
                {
                    title: '',
                    html: `<div style="font-size:11px;margin:0 0 8px">
                        Provider: ${providerHtml}${modelNote ? ' · ' + modelNote : ''}<br>
                        <span style="color:#777">Generation typically takes ${estSec < 30 ? 'a few seconds' : estSec < 90 ? '30–90 seconds on local GPU' : '1–3 minutes on local GPU'}.</span>
                    </div>`,
                },
                {
                    name: 'prompt',
                    title: 'Describe your image:',
                    type: 'textarea',
                    value: '',
                    placeholder: "e.g. 'a serene mountain lake at sunset, cinematic lighting'",
                },
                {
                    name: 'negative_prompt',
                    title: 'Avoid (optional):',
                    value: '',
                    placeholder: 'blurry, distorted, watermark',
                },
                {
                    name: 'width',
                    title: 'Width (px):',
                    value: defaultW,
                    range: [256, 2048],
                    step: 64,
                    type: 'range',
                },
                {
                    name: 'height',
                    title: 'Height (px):',
                    value: defaultH,
                    range: [256, 2048],
                    step: 64,
                    type: 'range',
                },
                {
                    name: 'placement',
                    title: 'Add as:',
                    value: 'new_layer',
                    values: ['new_layer', 'replace_canvas'],
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
                    name: 'seed',
                    title: 'Seed (0 = random):',
                    value: 0,
                    range: [0, 2147483647],
                    step: 1,
                    type: 'range',
                },
            ],
            on_finish: async function (params) {
                if (!params.prompt || !params.prompt.trim()) {
                    alertify.warning('Please enter a description.');
                    return;
                }
                await _this._generate(params, estSec);
            },
        });
    }

    async _generate(params, estSec) {
        if (this.isProcessing) return;
        this.isProcessing = true;

        connectProgressSSE('txt2img', window.API_BASE_URL || '');
        showProgress('Generating image…', estSec || 60);

        try {
            var result = await apiService.textToImage(params.prompt, {
                width:          params.width  || 1024,
                height:         params.height || 1024,
                negativePrompt: params.negative_prompt || '',
                steps:          params.steps  || 30,
                seed:           params.seed   || 0,
            });

            updateProgress(95, 'Placing image…');

            var img = new Image();
            img.onload = () => {
                if (params.placement === 'replace_canvas') {
                    config.WIDTH  = img.naturalWidth;
                    config.HEIGHT = img.naturalHeight;
                    var resultCanvas = document.createElement('canvas');
                    resultCanvas.width  = img.naturalWidth;
                    resultCanvas.height = img.naturalHeight;
                    resultCanvas.getContext('2d').drawImage(img, 0, 0);
                    app.State.do_action(
                        new app.Actions.Bundle_action('txt2img_replace', 'Text → Image', [
                            new app.Actions.Update_layer_image_action(resultCanvas)
                        ])
                    );
                } else {
                    app.State.do_action(
                        new app.Actions.Bundle_action('txt2img_layer', 'Text → Image Layer', [
                            new app.Actions.Insert_layer_action({
                                name: params.prompt.slice(0, 30),
                                type: 'image',
                                data: img.src,
                                x: 0, y: 0,
                                width:          img.naturalWidth,
                                height:         img.naturalHeight,
                                width_original: img.naturalWidth,
                                height_original: img.naturalHeight,
                            })
                        ])
                    );
                }
                disconnectProgressSSE();
                hideProgress();
                alertify.success('Image generated!');
                this.isProcessing = false;
            };
            img.onerror = () => {
                disconnectProgressSSE();
                hideProgress();
                alertify.error('Failed to load generated image.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            disconnectProgressSSE();
            hideProgress();
            alertify.error('Generation failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

function _shortGpu(name) {
    if (!name) return 'GPU';
    return name.replace(/^NVIDIA GeForce /i, '').replace(/^NVIDIA /i, '');
}

export default Generate_text_to_image_class;
