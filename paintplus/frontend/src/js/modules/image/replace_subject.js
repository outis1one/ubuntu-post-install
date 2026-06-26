/**
 * Replace Subject — extract the primary subject from a source photo and
 * composite it onto the current layer's background.
 *
 * Workflow:
 *   1. User selects the subject area via Smart Select (optional but recommended).
 *   2. Opens this module → picks a source photo.
 *   3. Backend removes the background from the source photo (rembg / AI),
 *      scales the extracted subject to fit the selection (or the canvas center),
 *      applies LAB color transfer so the lighting matches the background, and
 *      returns the composited image.
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import { showProgress, hideProgress } from './../../libs/progress_overlay.js';

const BASE = window.API_BASE_URL || '';

var instance = null;

class Image_replace_subject_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.Base_layers = new Base_layers_class();
        this.isProcessing = false;
    }

    replace_subject() {
        if (this.isProcessing) {
            alertify.warning('Already processing… please wait');
            return;
        }
        if (config.layer.type !== 'image') {
            alertify.error('Current layer must be an image.');
            return;
        }
        this._showDialog();
    }

    // ── Private ───────────────────────────────────────────────────────────────

    _showDialog() {
        var hasSel = !!(window.smartSelectMask && window.smartSelectMask.canvas);

        // Build a dialog manually so we can embed a file input
        var overlay = document.createElement('div');
        overlay.style.cssText = [
            'position:fixed', 'inset:0', 'background:rgba(0,0,0,0.6)',
            'z-index:20000', 'display:flex', 'align-items:center', 'justify-content:center',
        ].join(';');

        var box = document.createElement('div');
        box.style.cssText = [
            'background:#1a1a2e', 'border:1px solid #3a3a6a', 'border-radius:12px',
            'padding:24px', 'min-width:380px', 'max-width:460px',
            'font-family:sans-serif', 'color:#d0d0e0', 'font-size:13px',
        ].join(';');

        // Title
        var title = document.createElement('div');
        title.textContent = 'Replace Subject';
        title.style.cssText = 'font-size:16px;font-weight:bold;color:#aaaaff;margin-bottom:6px';
        box.appendChild(title);

        var sub = document.createElement('div');
        sub.textContent = hasSel
            ? 'Subject will be placed inside your current selection.'
            : 'No selection active — subject will be centred on the canvas.  Use Smart Select first for precise placement.';
        sub.style.cssText = 'font-size:11px;color:#7777aa;margin-bottom:16px;line-height:1.4';
        box.appendChild(sub);

        // File picker label + preview row
        var fileRow = document.createElement('div');
        fileRow.style.cssText = 'display:flex;align-items:center;gap:10px;margin-bottom:12px';
        var fileLabel = document.createElement('label');
        fileLabel.textContent = 'Source photo:';
        fileLabel.style.cssText = 'color:#aaa;width:100px;flex-shrink:0';
        var fileInput = document.createElement('input');
        fileInput.type = 'file';
        fileInput.accept = 'image/*';
        fileInput.style.cssText = 'flex:1;background:#0f0f1a;color:#ccc;border:1px solid #4a4a8a;border-radius:5px;padding:4px 8px;font-size:12px;cursor:pointer';
        fileRow.appendChild(fileLabel);
        fileRow.appendChild(fileInput);
        box.appendChild(fileRow);

        // Thumbnail preview
        var preview = document.createElement('img');
        preview.style.cssText = 'display:none;max-width:100%;max-height:160px;border-radius:6px;margin-bottom:12px;border:1px solid #3a3a6a';
        box.appendChild(preview);
        fileInput.addEventListener('change', () => {
            var f = fileInput.files[0];
            if (!f) return;
            var url = URL.createObjectURL(f);
            preview.src = url;
            preview.style.display = 'block';
            preview.onload = () => URL.revokeObjectURL(url);
        });

        // Match colors checkbox
        var colorRow = document.createElement('div');
        colorRow.style.cssText = 'display:flex;align-items:center;gap:8px;margin-bottom:16px';
        var colorCheck = document.createElement('input');
        colorCheck.type = 'checkbox';
        colorCheck.checked = true;
        colorCheck.id = 'rs-match-colors';
        var colorLabel = document.createElement('label');
        colorLabel.htmlFor = 'rs-match-colors';
        colorLabel.textContent = 'Match background lighting & color tone';
        colorLabel.style.cssText = 'color:#bbb;cursor:pointer';
        colorRow.appendChild(colorCheck);
        colorRow.appendChild(colorLabel);
        box.appendChild(colorRow);

        // Buttons
        var btnRow = document.createElement('div');
        btnRow.style.cssText = 'display:flex;gap:8px;justify-content:flex-end';

        var cancelBtn = _btn('Cancel', '#2a2a4a', '#8888aa');
        cancelBtn.onclick = () => { document.body.removeChild(overlay); };

        var goBtn = _btn('Replace Subject', '#1a3a5a', '#88ccff');
        goBtn.style.fontWeight = 'bold';
        goBtn.onclick = async () => {
            var file = fileInput.files[0];
            if (!file) {
                alertify.warning('Please pick a source photo first.');
                return;
            }
            document.body.removeChild(overlay);
            await this._run(file, colorCheck.checked);
        };

        btnRow.appendChild(cancelBtn);
        btnRow.appendChild(goBtn);
        box.appendChild(btnRow);

        overlay.appendChild(box);
        overlay.addEventListener('click', (e) => { if (e.target === overlay) document.body.removeChild(overlay); });
        document.body.appendChild(overlay);
    }

    async _run(file, matchColors) {
        this.isProcessing = true;
        showProgress('Extracting subject and compositing…', 20);

        try {
            var subjectBase64 = await _fileToBase64(file);
            var bgBase64      = _getLayerBase64();
            var maskBase64    = _getMaskBase64();

            var res = await _post('/api/image/replace-subject', {
                background_image: bgBase64,
                subject_image:    subjectBase64,
                mask:             maskBase64 || undefined,
                match_colors:     matchColors,
            });

            var img = new Image();
            img.onload = () => {
                var canvas = document.createElement('canvas');
                canvas.width  = img.width;
                canvas.height = img.height;
                canvas.getContext('2d').drawImage(img, 0, 0);

                app.State.do_action(
                    new app.Actions.Bundle_action('replace_subject', 'Replace Subject', [
                        new app.Actions.Update_layer_image_action(canvas, config.layer.id)
                    ])
                );

                // Clear selection if one was used
                if (window.smartSelectMask) {
                    window.smartSelectMask = null;
                    config.need_render = true;
                }

                hideProgress();
                alertify.success('Subject replaced!');
                this.isProcessing = false;
            };
            img.onerror = () => {
                hideProgress();
                alertify.error('Failed to load result image.');
                this.isProcessing = false;
            };
            img.src = 'data:image/png;base64,' + res.result;

        } catch (e) {
            hideProgress();
            alertify.error('Replace subject failed: ' + (e.message || e));
            this.isProcessing = false;
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function _getLayerBase64() {
    var canvas = document.createElement('canvas');
    canvas.width  = config.layer.width_original;
    canvas.height = config.layer.height_original;
    canvas.getContext('2d').drawImage(config.layer.link, 0, 0);
    return canvas.toDataURL('image/png').split(',')[1];
}

function _getMaskBase64() {
    var m = window.smartSelectMask;
    if (!m || !m.canvas) return null;
    var w = config.layer.width_original;
    var h = config.layer.height_original;
    var canvas = document.createElement('canvas');
    canvas.width  = w;
    canvas.height = h;
    canvas.getContext('2d').drawImage(m.canvas, 0, 0, w, h);
    return canvas.toDataURL('image/png').split(',')[1];
}

function _fileToBase64(file) {
    return new Promise((resolve, reject) => {
        var reader = new FileReader();
        reader.onload  = (e) => resolve(e.target.result.split(',')[1]);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
}

function _btn(text, bg, color) {
    var b = document.createElement('button');
    b.textContent = text;
    b.style.cssText = 'background:' + bg + ';color:' + color + ';border:1px solid #3a3a6a;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:12px';
    return b;
}

async function _post(path, body) {
    var r = await fetch(BASE + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });
    if (!r.ok) {
        var err = await r.json().catch(() => ({ detail: r.statusText }));
        throw new Error(err.detail || 'Request failed');
    }
    return r.json();
}

export default Image_replace_subject_class;
