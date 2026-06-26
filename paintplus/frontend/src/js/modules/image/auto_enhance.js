/**
 * Auto-Enhance — one-click smart photo improvement.
 * Applies auto white balance, CLAHE contrast, saturation boost, and mild sharpening.
 * Strength slider lets the user dial in how strong the effect is.
 *
 * Menu target: image/auto_enhance.auto_enhance
 */

import app from './../../app.js';
import config from './../../config.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

class Image_auto_enhance_class {
    constructor() {
        if (instance) return instance;
        instance = this;
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
    }

    async auto_enhance() {
        if (!config.layer || config.layer.type !== 'image') {
            alertify.error('Select an image layer first.');
            return;
        }
        var _this = this;
        this.Dialog.show({
            title: 'Auto-Enhance',
            params: [
                {
                    title: '',
                    html: `<div style="font-size:11px;color:#888;margin-bottom:8px;">
                        Automatically improves white balance, contrast, saturation, and sharpness.
                    </div>`,
                },
                {
                    name: 'strength',
                    title: 'Strength:',
                    value: '100',
                    values: ['25', '50', '75', '100'],
                    type: 'select',
                },
                {
                    name: 'new_layer',
                    title: 'Keep original as separate layer:',
                    value: false,
                },
            ],
            on_finish: async function (params) {
                await _this._run(parseFloat(params.strength) / 100, params.new_layer);
            },
        });
    }

    async _run(strength, newLayer) {
        if (this.isProcessing) return;
        this.isProcessing = true;
        alertify.message('Enhancing…', 0);

        try {
            const layer = config.layer;
            const c = document.createElement('canvas');
            c.width = layer.width_original; c.height = layer.height_original;
            c.getContext('2d').drawImage(layer.link, 0, 0);
            const imageB64 = c.toDataURL('image/png').split(',')[1];

            const base = window.API_BASE_URL || '';
            const r = await fetch(`${base}/api/enhance`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ image: imageB64, strength }),
            });
            if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || 'Failed');
            const data = await r.json();

            const img = new Image();
            img.onload = () => {
                const rc = document.createElement('canvas');
                rc.width = img.naturalWidth; rc.height = img.naturalHeight;
                rc.getContext('2d').drawImage(img, 0, 0);

                if (newLayer) {
                    app.State.do_action(
                        new app.Actions.Bundle_action('auto_enhance', 'Auto-Enhance', [
                            new app.Actions.Insert_layer_action({
                                name: layer.name + ' (Enhanced)',
                                type: 'image',
                                data: img.src,
                                x: layer.x, y: layer.y,
                                width: img.naturalWidth, height: img.naturalHeight,
                                width_original: img.naturalWidth, height_original: img.naturalHeight,
                            })
                        ])
                    );
                } else {
                    app.State.do_action(
                        new app.Actions.Bundle_action('auto_enhance', 'Auto-Enhance', [
                            new app.Actions.Update_layer_image_action(rc)
                        ])
                    );
                }
                alertify.dismissAll();
                alertify.success('Enhancement applied.');
                this.isProcessing = false;
            };
            img.onerror = () => {
                alertify.dismissAll();
                alertify.error('Failed to load result.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + data.result;

        } catch (err) {
            alertify.dismissAll();
            alertify.error('Auto-enhance failed: ' + (err.message || err));
            this.isProcessing = false;
        }
    }
}

export default Image_auto_enhance_class;
