/**
 * Upscale — increase image resolution.
 * Fetches available methods from /api/print/upscale/available on first open.
 * Auto-selects the recommended method; user can override.
 * If no AI upscaler is found, polls /api/print/upscale/install-status while
 * the backend auto-installs Real-ESRGAN NCNN Vulkan, then refreshes and continues.
 *
 * Menu target: image/upscale.upscale
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import { showProgress, updateProgress, hideProgress } from './../../libs/progress_overlay.js';

var instance = null;

const METHOD_LABELS = {
    auto:                'Auto (best available)',
    realesrgan_pytorch:  'Real-ESRGAN — PyTorch',
    realesrgan_ncnn:     'Real-ESRGAN — NCNN Vulkan',
    lanczos:             'Lanczos (fast, no AI)',
};

class Image_upscale_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.Base_layers = new Base_layers_class();
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
        this._caps = null;
    }

    async upscale() {
        if (!config.layer || config.layer.type !== 'image') {
            alertify.error('Select an image layer first.');
            return;
        }

        // If a previous caps fetch showed no AI upscaler, check install progress
        var caps = await this._fetchCaps();
        if (!caps.realesrgan_pytorch && !caps.realesrgan_ncnn) {
            await this._waitForInstall(caps);
            // Re-fetch caps after install
            this._caps = null;
            caps = await this._fetchCaps();
        }

        this._showDialog(caps);
    }

    _showDialog(caps) {
        var W = config.layer.width_original;
        var H = config.layer.height_original;

        var available = ['auto', ...caps.methods];
        var methodValues = [...new Set(available)];

        var methodLabels = methodValues.map(m => {
            var label = METHOD_LABELS[m] || m;
            if (m === 'auto') {
                label = `Auto → ${caps.recommended_label}`;
            } else if (m === caps.recommended && m !== 'auto') {
                label += ' ★';
            }
            return label;
        });

        var deviceNote = '';
        if (caps.realesrgan_pytorch) {
            var dev = caps.realesrgan_pytorch_device;
            var devLabel = dev === 'cuda' ? 'CUDA GPU'
                         : dev === 'mps'  ? 'Apple Silicon'
                         : 'CPU (slow — ~1–3 min for large images)';
            deviceNote += `PyTorch: ${devLabel}. `;
        }
        if (caps.realesrgan_ncnn) {
            deviceNote += 'NCNN Vulkan binary found. ';
        }
        if (!caps.realesrgan_pytorch && !caps.realesrgan_ncnn) {
            var installState = (caps.ncnn_install_status || {}).state;
            if (installState === 'skipped') {
                deviceNote = 'Headless server — no Vulkan GPU. Lanczos only. '
                    + 'Install Real-ESRGAN PyTorch for AI quality on CPU.';
            } else {
                deviceNote = 'No AI upscaler available — Lanczos only.';
            }
        }

        var _this = this;

        this.Dialog.show({
            title: 'Upscale Image',
            params: [
                {
                    title: '',
                    html: `<div style="font-size:11px;color:#888;margin:0 0 8px;">
                        Current: ${W}×${H}px<br>
                        ${deviceNote}
                    </div>`,
                },
                {
                    name: 'scale',
                    title: 'Scale factor:',
                    value: '2×',
                    values: ['1.5×', '2×', '3×', '4×'],
                    type: 'select',
                },
                {
                    name: 'method',
                    title: 'Method:',
                    value: methodLabels[0],
                    values: methodLabels,
                    type: 'select',
                },
                {
                    name: 'new_layer',
                    title: 'Result as new layer (keep original):',
                    value: false,
                },
            ],
            on_finish: async function (params) {
                var labelIdx = methodLabels.indexOf(params.method);
                var methodKey = labelIdx >= 0 ? methodValues[labelIdx] : 'auto';
                var scale = parseFloat(params.scale);
                await _this._run(scale, methodKey, params.new_layer);
            },
        });
    }

    /**
     * Poll install-status until done/failed/skipped, showing a progress bar.
     * On headless machines the server sets state=skipped immediately — no wait.
     */
    async _waitForInstall(caps) {
        var installStatus = caps.ncnn_install_status || {};
        var terminalStates = ['done', 'failed', 'skipped'];
        if (terminalStates.includes(installStatus.state)) {
            if (installStatus.state === 'skipped') {
                // Headless — just proceed, dialog will show Lanczos or PyTorch CPU
                alertify.message(installStatus.message || 'No Vulkan GPU — using CPU upscaler.', 4);
            }
            return;
        }

        return new Promise((resolve) => {
            alertify.message(
                `<div>Installing Real-ESRGAN AI upscaler…<br>
                <progress id="esrgan-install-progress" value="0" max="100"
                  style="width:100%;margin-top:6px;"></progress>
                <span id="esrgan-install-pct">0%</span></div>`,
                0
            );

            var poll = setInterval(async () => {
                try {
                    var base = window.API_BASE_URL || '';
                    var r = await fetch(`${base}/api/print/upscale/install-status`);
                    if (!r.ok) return;
                    var s = await r.json();

                    var bar = document.getElementById('esrgan-install-progress');
                    var pct = document.getElementById('esrgan-install-pct');
                    if (bar) bar.value = s.progress || 0;
                    if (pct) pct.textContent = `${s.progress || 0}%`;

                    if (s.state === 'done') {
                        clearInterval(poll);
                        alertify.dismissAll();
                        alertify.success('Real-ESRGAN NCNN installed.');
                        resolve();
                    } else if (s.state === 'skipped') {
                        clearInterval(poll);
                        alertify.dismissAll();
                        alertify.message(s.message || 'No Vulkan GPU — using CPU upscaler.', 4);
                        resolve();
                    } else if (s.state === 'failed') {
                        clearInterval(poll);
                        alertify.dismissAll();
                        alertify.warning('AI upscaler install failed — using Lanczos.');
                        resolve();
                    }
                } catch { /* network hiccup, keep polling */ }
            }, 1500);
        });
    }

    async _fetchCaps() {
        if (this._caps) return this._caps;
        try {
            var base = window.API_BASE_URL || '';
            var r = await fetch(`${base}/api/print/upscale/available`);
            if (r.ok) {
                this._caps = await r.json();
            }
        } catch { /* ignore */ }

        if (!this._caps) {
            this._caps = {
                lanczos: true,
                realesrgan_pytorch: false,
                realesrgan_ncnn: false,
                recommended: 'lanczos',
                recommended_label: 'Lanczos',
                methods: ['lanczos'],
                ncnn_install_status: { state: 'idle', progress: 0 },
            };
        }
        return this._caps;
    }

    async _run(scale, method, newLayer) {
        if (this.isProcessing) return;
        this.isProcessing = true;

        var caps = this._caps || {};
        var methodLabel = method === 'auto'
            ? `Auto (${caps.recommended_label || 'best available'})`
            : (METHOD_LABELS[method] || method);

        var isAI = method !== 'lanczos';
        showProgress(
            `Upscaling ${scale}× with ${methodLabel}…` +
            (isAI ? '\nAI is reconstructing detail — this may take 30–120 seconds.' : ''),
            isAI ? 90 : 10
        );

        try {
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = config.layer.width_original;
            layerCanvas.height = config.layer.height_original;
            layerCanvas.getContext('2d').drawImage(config.layer.link, 0, 0);
            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];

            var base = window.API_BASE_URL || '';
            var r = await fetch(`${base}/api/print/upscale`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ image: imageB64, scale, method }),
            });

            if (!r.ok) {
                var err = await r.json().catch(() => ({ detail: 'Server error' }));
                throw new Error(err.detail || 'Upscale failed');
            }
            var result = await r.json();

            var img = new Image();
            img.onload = () => {
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = img.naturalWidth;
                resultCanvas.height = img.naturalHeight;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                var usedLabel = result.method.replace('realesrgan_pytorch_', 'ESRGAN/')
                                             .replace('realesrgan_ncnn', 'ESRGAN/NCNN');

                if (newLayer) {
                    app.State.do_action(
                        new app.Actions.Bundle_action('upscale_layer', 'Upscale', [
                            new app.Actions.Insert_layer_action({
                                name: `${scale}× ${usedLabel}`,
                                type: 'image',
                                data: img.src,
                                x: 0, y: 0,
                                width: img.naturalWidth,
                                height: img.naturalHeight,
                                width_original: img.naturalWidth,
                                height_original: img.naturalHeight,
                            })
                        ])
                    );
                } else {
                    app.State.do_action(
                        new app.Actions.Bundle_action('upscale', 'Upscale', [
                            new app.Actions.Update_layer_image_action(resultCanvas)
                        ])
                    );
                }

                hideProgress();
                alertify.success(
                    `${result.output.width}×${result.output.height}px · ${usedLabel}`
                );
                this.isProcessing = false;
            };
            img.onerror = () => {
                hideProgress();
                alertify.error('Failed to load upscaled image.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            hideProgress();
            alertify.error('Upscale failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

export default Image_upscale_class;
