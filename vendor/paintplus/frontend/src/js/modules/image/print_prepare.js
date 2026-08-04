/**
 * Prepare for Print — one-click AI upscale + frame fit.
 *
 * Shows a quality assessment (current effective DPI, needed upscale factor,
 * AI vs Lanczos note) then chains AI upscale → frame-fit in a single backend call.
 *
 * Menu target: image/print_prepare.print_prepare
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import { getCapabilities } from './../../api/capabilities.js';
import { showProgress, updateProgress, hideProgress } from './../../libs/progress_overlay.js';

const FRAME_SIZES = [
    '5x7', '8x10', '11x14', '18x24', '16x20', '20x24', '24x36',
];

// Portrait pixels at 300 DPI (label use only)
const FRAME_PX = {
    '5x7':   [1500, 2100], '8x10':  [2400, 3000],
    '11x14': [3300, 4200], '18x24': [5400, 7200],
    '16x20': [4800, 6000], '20x24': [6000, 7200],
    '24x36': [7200, 10800],
};

// Actual frame inches (portrait w, h)
const FRAME_IN = {
    '5x7':   [5, 7],   '8x10':  [8, 10],  '11x14': [11, 14],
    '18x24': [18, 24], '16x20': [16, 20], '20x24': [20, 24],
    '24x36': [24, 36],
};

var instance = null;

class Image_print_prepare_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.Base_layers = new Base_layers_class();
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
    }

    async print_prepare() {
        if (!config.layer || config.layer.type !== 'image') {
            alertify.error('Select an image layer first.');
            return;
        }

        var caps = await getCapabilities();
        var hasAI = (caps.remote && caps.remote.healthy) || (caps.local && caps.local.local_gpu_available);

        var W = config.layer.width_original;
        var H = config.layer.height_original;

        var qualityHtml = _buildQualityHtml(W, H, hasAI);

        var frameLabels = FRAME_SIZES.map(s => {
            var px = FRAME_PX[s] || [0, 0];
            return `${s}" (${px[0]}×${px[1]}px @ 300dpi)`;
        });

        var _this = this;
        this.Dialog.show({
            title: 'Prepare for Print',
            params: [
                {
                    title: '',
                    html: qualityHtml,
                },
                {
                    name: 'frame',
                    title: 'Target frame size:',
                    value: frameLabels[0],
                    values: frameLabels,
                    type: 'select',
                },
                {
                    name: 'orientation',
                    title: 'Orientation:',
                    value: 'auto',
                    values: ['auto', 'portrait', 'landscape'],
                    type: 'select',
                },
                {
                    name: 'target_dpi',
                    title: 'Target DPI:',
                    value: '300',
                    values: ['200', '300'],
                    type: 'select',
                    comment: '200 dpi is fine for 18×24" and larger (viewed from a distance)',
                },
                {
                    name: 'mode',
                    title: 'Fit mode:',
                    value: 'smart',
                    values: ['smart', 'crop', 'extend'],
                    type: 'select',
                    comment: 'smart = extend if gap <15%, else crop',
                },
                {
                    name: 'upscale_method',
                    title: 'Upscale engine:',
                    value: 'auto',
                    values: ['auto', 'realesrgan_pytorch', 'realesrgan_ncnn', 'lanczos'],
                    type: 'select',
                    comment: hasAI ? 'auto picks Real-ESRGAN — genuinely adds detail' : 'auto picks Real-ESRGAN if available, else Lanczos',
                },
                {
                    name: 'prompt',
                    title: 'Extend prompt (optional):',
                    value: '',
                    placeholder: 'e.g. "natural background continuation" — blank works well',
                },
                {
                    name: 'new_layer',
                    title: 'Result as new layer (keep original):',
                    value: true,
                },
            ],
            on_finish: async function (params) {
                var frameKey = params.frame.split('"')[0];
                await _this._run(frameKey, params, W, H);
            },
        });
    }

    async _run(frameKey, params, origW, origH) {
        if (this.isProcessing) return;
        this.isProcessing = true;

        var dpi = parseInt(params.target_dpi) || 300;
        var inches = FRAME_IN[frameKey] || [8, 10];
        var targetW = inches[0] * dpi;
        var targetH = inches[1] * dpi;

        // Orientation swap for display
        var orient = params.orientation || 'auto';
        var imgLandscape = origW >= origH;
        var frameLandscape = inches[0] >= inches[1];
        if (orient === 'landscape' || (orient === 'auto' && imgLandscape && !frameLandscape)) {
            targetW = Math.max(inches[0], inches[1]) * dpi;
            targetH = Math.min(inches[0], inches[1]) * dpi;
        } else if (orient === 'portrait' || (orient === 'auto' && !imgLandscape && frameLandscape)) {
            targetW = Math.min(inches[0], inches[1]) * dpi;
            targetH = Math.max(inches[0], inches[1]) * dpi;
        }

        var neededScale = Math.max(targetW / origW, targetH / origH);
        var willUpscale = neededScale > 1.05;

        showProgress(
            willUpscale
                ? `Upscaling ${neededScale.toFixed(1)}× with AI, then fitting to frame…\nAI is reconstructing detail — this may take 1–3 minutes.`
                : 'Fitting to frame…',
            willUpscale ? 120 : 8
        );

        try {
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = origW;
            layerCanvas.height = origH;
            layerCanvas.getContext('2d').drawImage(config.layer.link, 0, 0);
            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];

            var base = window.API_BASE_URL || '';
            var r = await fetch(`${base}/api/print/prepare`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    image: imageB64,
                    frame: frameKey,
                    orientation: orient,
                    target_dpi: dpi,
                    upscale_method: params.upscale_method || 'auto',
                    mode: params.mode || 'smart',
                    prompt: params.prompt || '',
                }),
            });

            if (!r.ok) {
                var err = await r.json().catch(() => ({ detail: 'Server error' }));
                throw new Error(err.detail || 'Prepare failed');
            }
            var result = await r.json();

            updateProgress(90, 'Placing result…');
            var img = new Image();
            img.onload = () => {
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = img.naturalWidth;
                resultCanvas.height = img.naturalHeight;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                var fitW = img.naturalWidth;
                var fitH = img.naturalHeight;

                if (params.new_layer) {
                    app.State.do_action(
                        new app.Actions.Bundle_action('print_prepare_layer', 'Prepare for Print', [
                            new app.Actions.Prepare_canvas_action('undo'),
                            new app.Actions.Update_config_action({ WIDTH: fitW, HEIGHT: fitH }),
                            new app.Actions.Insert_layer_action({
                                name: `${frameKey} ${dpi}dpi`,
                                type: 'image',
                                data: img.src,
                                x: 0, y: 0,
                                width: fitW, height: fitH,
                                width_original: fitW, height_original: fitH,
                            }),
                            new app.Actions.Prepare_canvas_action('do'),
                        ])
                    );
                } else {
                    app.State.do_action(
                        new app.Actions.Bundle_action('print_prepare', 'Prepare for Print', [
                            new app.Actions.Prepare_canvas_action('undo'),
                            new app.Actions.Update_config_action({ WIDTH: fitW, HEIGHT: fitH }),
                            new app.Actions.Update_layer_image_action(resultCanvas),
                            new app.Actions.Prepare_canvas_action('do'),
                        ])
                    );
                }

                hideProgress();
                var upscaleNote = result.upscale_applied
                    ? ` · ${result.upscale_factor}× ${result.upscale_method}`
                    : ' · no upscale needed';
                alertify.success(
                    `Print-ready! ${fitW}×${fitH}px @ ${dpi} DPI (${frameKey}")${upscaleNote}`
                );
                this.isProcessing = false;
            };
            img.onerror = () => {
                hideProgress();
                alertify.error('Failed to load result.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + result.result;

        } catch (err) {
            hideProgress();
            alertify.error('Prepare for Print failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

function _buildQualityHtml(W, H, hasAI) {
    var rows = FRAME_SIZES.map(key => {
        var inches = FRAME_IN[key];
        // Effective DPI: smaller of the two dimensions (limiting factor)
        var effDpi = Math.round(Math.min(W / inches[0], H / inches[1]));
        var quality = effDpi >= 300 ? '✓ excellent'
                    : effDpi >= 200 ? '✓ good for large format'
                    : effDpi >= 150 ? '~ acceptable'
                    : '✗ needs upscaling';
        var color = effDpi >= 300 ? '#44cc44'
                  : effDpi >= 200 ? '#88cc44'
                  : effDpi >= 150 ? '#ffaa44'
                  : '#ff6644';
        var neededScale = Math.max(1, Math.ceil((300 / effDpi) * 10) / 10);
        var scaleNote = effDpi >= 300 ? '' : ` → need ~${neededScale.toFixed(1)}× upscale`;
        return `<tr>
            <td style="color:#aaa;padding:2px 10px 2px 0;white-space:nowrap">${key}"</td>
            <td style="color:#ddd;white-space:nowrap">${effDpi} DPI</td>
            <td style="color:${color};padding-left:8px">${quality}${scaleNote}</td>
        </tr>`;
    }).join('');

    var aiNote = hasAI
        ? '<span style="color:#44cc44">Real-ESRGAN available — will add genuine sharpness (AI reconstructs detail)</span>'
        : '<span style="color:#ffaa44">No AI provider — will use Lanczos (resizes but doesn\'t add detail)</span>';

    return `<div style="font-size:11px;margin:0 0 8px">
        <div style="color:#aaa;margin-bottom:6px">Current image: <span style="color:#ddd">${W}×${H}px</span> · ${aiNote}</div>
        <table style="width:100%;border-collapse:collapse;margin-bottom:6px">${rows}</table>
        <div style="color:#888">200 DPI is fine for 18×24" and larger prints viewed from 2+ feet.</div>
    </div>`;
}

export default Image_print_prepare_class;
