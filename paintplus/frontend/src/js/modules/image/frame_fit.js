/**
 * Fit to Frame — resize/extend/crop image to a standard print frame size.
 *
 * Modes:
 *   crop   — center-crop to aspect ratio, scale to print resolution (no AI needed)
 *   extend — scale to fill one dimension, AI-outpaint the gap (needs provider)
 *   smart  — auto-pick: extend if gap < 15% of dimension, else crop
 *
 * Menu target: image/frame_fit.frame_fit
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import { getCapabilities } from './../../api/capabilities.js';
import { showProgress, hideProgress } from './../../libs/progress_overlay.js';

var instance = null;

const FRAME_SIZES = [
    '4x6', '5x7', '8x10', '11x14', '16x20', '18x24', '20x24', '24x36',
    '4x4', '8x8', '12x12',
];

// Pixels at 300 dpi for preview labels
const FRAME_PX = {
    '4x6':   [1200, 1800], '5x7':   [1500, 2100],
    '8x10':  [2400, 3000], '11x14': [3300, 4200],
    '16x20': [4800, 6000], '18x24': [5400, 7200],
    '20x24': [6000, 7200], '24x36': [7200, 10800],
    '4x4':   [1200, 1200], '8x8': [2400, 2400], '12x12': [3600, 3600],
};

class Image_frame_fit_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.Base_layers = new Base_layers_class();
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
    }

    async frame_fit() {
        if (!config.layer || config.layer.type !== 'image') {
            alertify.error('Select an image layer first.');
            return;
        }

        var caps = await getCapabilities();
        var hasRemote = caps.remote && caps.remote.healthy;

        var _this = this;
        var W = config.layer.width_original;
        var H = config.layer.height_original;

        // Build display labels with pixel sizes
        var sizeLabels = FRAME_SIZES.map(s => {
            var px = FRAME_PX[s] || [0, 0];
            return `${s}" (${px[0]}×${px[1]}px @ 300dpi)`;
        });

        this.Dialog.show({
            title: 'Fit to Frame',
            params: [
                {
                    title: '',
                    html: `<div style="font-size:11px;color:#888;margin:0 0 8px;">
                        Current image: ${W}×${H}px<br>
                        Crop = no AI needed. Extend = AI fills the gaps${hasRemote ? '' : ' <span style="color:#ffaa00">(no provider configured — extend will use mirror fill)</span>'}.
                    </div>`,
                },
                {
                    name: 'frame',
                    title: 'Frame size:',
                    value: sizeLabels[1], // default 5x7
                    values: sizeLabels,
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
                    name: 'mode',
                    title: 'Fit mode:',
                    value: 'smart',
                    values: ['smart', 'crop', 'extend'],
                    type: 'select',
                },
                {
                    name: 'dpi',
                    title: 'Output DPI:',
                    value: '300',
                    values: ['72', '150', '200', '300'],
                    type: 'select',
                },
                {
                    name: 'prompt',
                    title: 'Extend prompt (optional):',
                    value: '',
                    placeholder: 'e.g. "continue the background naturally" — blank works well',
                },
                {
                    name: 'new_layer',
                    title: 'Result as new layer (keep original):',
                    value: true,
                },
            ],
            on_finish: async function (params) {
                var frameKey = params.frame.split('"')[0]; // strip label suffix back to "8x10"
                await _this._run(frameKey, params);
            },
        });
    }

    async _run(frameKey, params) {
        if (this.isProcessing) return;
        this.isProcessing = true;

        var mode = params.mode || 'smart';
        showProgress(
            mode === 'extend'
                ? 'Fitting to frame with AI extension…'
                : 'Fitting to frame…',
            mode === 'extend' ? 45 : 5
        );

        try {
            var layerCanvas = document.createElement('canvas');
            layerCanvas.width  = config.layer.width_original;
            layerCanvas.height = config.layer.height_original;
            layerCanvas.getContext('2d').drawImage(config.layer.link, 0, 0);
            var imageB64 = layerCanvas.toDataURL('image/png').split(',')[1];

            var base = window.API_BASE_URL || '';
            var r = await fetch(`${base}/api/print/frame-fit`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    image: imageB64,
                    frame: frameKey,
                    orientation: params.orientation || 'auto',
                    mode: params.mode || 'smart',
                    dpi: parseInt(params.dpi) || 300,
                    prompt: params.prompt || '',
                }),
            });

            if (!r.ok) {
                var err = await r.json().catch(() => ({ detail: 'Server error' }));
                throw new Error(err.detail || 'Frame fit failed');
            }
            var result = await r.json();

            var img = new Image();
            img.onload = () => {
                var resultCanvas = document.createElement('canvas');
                resultCanvas.width  = img.naturalWidth;
                resultCanvas.height = img.naturalHeight;
                resultCanvas.getContext('2d').drawImage(img, 0, 0);

                var fitW = img.naturalWidth;
                var fitH = img.naturalHeight;

                if (params.new_layer) {
                    var dataURL = img.src;
                    app.State.do_action(
                        new app.Actions.Bundle_action('frame_fit_layer', 'Fit to Frame', [
                            new app.Actions.Prepare_canvas_action('undo'),
                            new app.Actions.Update_config_action({
                                WIDTH: fitW,
                                HEIGHT: fitH,
                            }),
                            new app.Actions.Insert_layer_action({
                                name: `${frameKey} fit`,
                                type: 'image',
                                data: dataURL,
                                x: 0, y: 0,
                                width: fitW,
                                height: fitH,
                                width_original: fitW,
                                height_original: fitH,
                            }),
                            new app.Actions.Prepare_canvas_action('do'),
                        ])
                    );
                } else {
                    app.State.do_action(
                        new app.Actions.Bundle_action('frame_fit', 'Fit to Frame', [
                            new app.Actions.Prepare_canvas_action('undo'),
                            new app.Actions.Update_config_action({
                                WIDTH: fitW,
                                HEIGHT: fitH,
                            }),
                            new app.Actions.Update_layer_image_action(resultCanvas),
                            new app.Actions.Prepare_canvas_action('do'),
                        ])
                    );
                }

                hideProgress();
                alertify.success(
                    `Done! ${result.output_pixels.width}×${result.output_pixels.height}px` +
                    ` (${result.frame} ${result.orientation}, ${result.mode_used})`
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
            alertify.error('Frame fit failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

export default Image_frame_fit_class;
