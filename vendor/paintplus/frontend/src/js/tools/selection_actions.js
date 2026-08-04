/**
 * SelectionActions — floating quick-action panel that appears after a SAM selection.
 *
 * Surfaces high-value real-world workflows directly in the UI:
 *   • Scale by %   — make object 3% (or any %) bigger/smaller, gap AI-filled
 *   • Make less symmetrical — AI redraws the region with organic variation
 *   • Replace with clipboard — paste clipboard image into the selection shape
 *   • Copy / Cut to layer — classic Photoshop workflow
 *   • AI Edit (custom prompt) — full inpaint with user text
 *
 * Usage:
 *   this.selectionActions = new SelectionActions(this);
 *   // after successful selection:
 *   this.selectionActions.show(imageBase64, maskBase64);
 */

import app from './../app.js';
import config from './../config.js';
import Base_layers_class from './../core/base-layers.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';
import { showProgress, updateProgress, hideProgress, connectProgressSSE, disconnectProgressSSE } from './../libs/progress_overlay.js';

const BASE = window.API_BASE_URL || '';

export class SelectionActions {
    constructor(tool) {
        this.tool = tool;
        this.Base_layers = new Base_layers_class();
        this._panel = null;
        this._imageData = null;
        this._maskData  = null;
        this._escHandler = null;
    }

    show(imageBase64, maskBase64) {
        this.hide();
        this._imageData = imageBase64;
        this._maskData  = maskBase64;

        var panel = document.createElement('div');
        panel.id = 'sel-actions-panel';
        panel.style.cssText = [
            'position:fixed',
            'bottom:80px',
            'left:50%',
            'transform:translateX(-50%)',
            'background:#1a1a2e',
            'border:1px solid #3a3a6a',
            'border-radius:12px',
            'padding:14px 16px',
            'z-index:10000',
            'font-family:sans-serif',
            'font-size:12px',
            'color:#d0d0e0',
            'min-width:360px',
            'max-width:420px',
            'box-shadow:0 8px 32px rgba(0,0,0,0.7)',
            'display:flex',
            'flex-direction:column',
            'gap:6px',
        ].join(';');

        // ── Title row ────────────────────────────────────────────────────────
        var titleRow = document.createElement('div');
        titleRow.style.cssText = 'display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:2px';
        var titleBlock = document.createElement('div');
        var title = document.createElement('div');
        title.textContent = 'Selection ready';
        title.style.cssText = 'font-size:13px;font-weight:bold;color:#aaaaff;line-height:1.3';
        var subtitle = document.createElement('div');
        subtitle.textContent = 'Nothing has changed yet — choose an action below';
        subtitle.style.cssText = 'font-size:10px;color:#7777aa;margin-top:1px';
        titleBlock.appendChild(title);
        titleBlock.appendChild(subtitle);
        var closeX = document.createElement('button');
        closeX.textContent = '✕';
        closeX.style.cssText = 'background:none;border:none;color:#666;cursor:pointer;font-size:14px;padding:0 0 0 8px;line-height:1;flex-shrink:0';
        closeX.title = 'Dismiss (keeps your selection active)';
        closeX.onclick = () => this.hide();
        titleRow.appendChild(titleBlock);
        titleRow.appendChild(closeX);
        panel.appendChild(titleRow);

        // ── Section: AI Actions ──────────────────────────────────────────────
        panel.appendChild(_sectionLabel('AI Actions'));

        // Scale by %
        var scaleWrap = document.createElement('div');
        scaleWrap.style.cssText = 'background:#16213e;border-radius:7px;padding:7px 10px';
        var scaleRow = document.createElement('div');
        scaleRow.style.cssText = 'display:flex;align-items:center;gap:6px';
        var scaleLabel = document.createElement('span');
        scaleLabel.textContent = 'Scale object by';
        scaleLabel.style.color = '#aaa';
        var scaleInput = document.createElement('input');
        scaleInput.type = 'number';
        scaleInput.value = '103';
        scaleInput.min = '1';
        scaleInput.max = '500';
        scaleInput.style.cssText = 'width:52px;background:#0f0f1a;color:#fff;border:1px solid #4a4a8a;border-radius:4px;padding:2px 5px;font-size:12px';
        var scaleUnit = document.createElement('span');
        scaleUnit.textContent = '%';
        scaleUnit.style.color = '#888';
        var scaleHint = document.createElement('span');
        scaleHint.style.cssText = 'color:#6688aa;font-size:10px;margin-left:2px';
        scaleHint.textContent = '= 3% bigger';
        var scaleBtn = _btn('Apply', '#1a2a4a', '#8aacff');
        scaleBtn.style.marginLeft = 'auto';
        scaleInput.addEventListener('input', () => {
            var v = parseFloat(scaleInput.value);
            if (isNaN(v) || v === 100) scaleHint.textContent = '= no change';
            else if (v > 100) scaleHint.textContent = '= ' + (v - 100).toFixed(0) + '% bigger';
            else scaleHint.textContent = '= ' + (100 - v).toFixed(0) + '% smaller';
        });
        scaleBtn.onclick = () => {
            var pct = parseFloat(scaleInput.value) || 103;
            this._scaleSelection(pct);
        };
        scaleRow.appendChild(scaleLabel);
        scaleRow.appendChild(scaleInput);
        scaleRow.appendChild(scaleUnit);
        scaleRow.appendChild(scaleHint);
        scaleRow.appendChild(scaleBtn);
        var scaleDesc = document.createElement('div');
        scaleDesc.textContent = 'Moves the selected object, then AI fills the vacated area';
        scaleDesc.style.cssText = 'color:#5566aa;font-size:10px;margin-top:4px';
        scaleWrap.appendChild(scaleRow);
        scaleWrap.appendChild(scaleDesc);
        panel.appendChild(scaleWrap);

        // Make less symmetrical
        panel.appendChild(_actionCard(
            'Make less symmetrical',
            '#1c1a2e', '#cc99ff',
            'AI redraws the selection with subtle, natural imperfections',
            () => this._makeAsymmetric()
        ));

        // Replace with clipboard
        panel.appendChild(_actionCard(
            'Replace with clipboard',
            '#1a2a1a', '#88dd88',
            'Scales your clipboard image to fit inside the selection shape',
            () => this._pasteFromClipboard()
        ));

        // Replace subject from file
        panel.appendChild(_actionCard(
            'Replace subject from file',
            '#1a2a2a', '#66ddcc',
            'Pick any photo — AI extracts its subject and places it here, matching background lighting',
            () => this._replaceSubjectFromFile()
        ));

        // Custom AI edit prompt
        var aiWrap = document.createElement('div');
        aiWrap.style.cssText = 'background:#16213e;border-radius:7px;padding:7px 10px';
        var aiRow = document.createElement('div');
        aiRow.style.cssText = 'display:flex;align-items:center;gap:6px';
        var aiInput = document.createElement('input');
        aiInput.type = 'text';
        aiInput.placeholder = '"add a scar", "make it look aged", "blue eyes" …';
        aiInput.style.cssText = 'flex:1;background:#0f0f1a;color:#fff;border:1px solid #4a4a8a;border-radius:4px;padding:3px 7px;font-size:11px';
        var aiBtn = _btn('AI Edit', '#1a2a4a', '#8aacff');
        aiBtn.onclick = () => {
            var instruction = aiInput.value.trim();
            if (!instruction) { alertify.warning('Enter an instruction first — describe what to change.'); return; }
            this._aiEditRegion(instruction);
        };
        aiInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') aiBtn.click();
        });
        var aiDesc = document.createElement('div');
        aiDesc.textContent = 'Inpaints the selected region according to your description';
        aiDesc.style.cssText = 'color:#5566aa;font-size:10px;margin-top:4px';
        aiRow.appendChild(aiInput);
        aiRow.appendChild(aiBtn);
        aiWrap.appendChild(aiRow);
        aiWrap.appendChild(aiDesc);
        panel.appendChild(aiWrap);

        // ── Section: Classic Tools ────────────────────────────────────────────
        panel.appendChild(_sectionLabel('Classic Tools'));
        var classicRow = document.createElement('div');
        classicRow.style.cssText = 'display:flex;gap:6px';
        var copyBtn = _btn('Copy to layer', '#1a2a1a', '#88cc88');
        copyBtn.style.flex = '1';
        copyBtn.title = 'Lift a copy of the selection onto a new layer (non-destructive)';
        copyBtn.onclick = () => { this.tool.copyToLayer(); this.hide(); };
        var cutBtn  = _btn('Cut to layer', '#2a1a1a', '#cc8888');
        cutBtn.style.flex = '1';
        cutBtn.title = 'Cut the selection to a new layer (erases from original)';
        cutBtn.onclick = () => { this.tool.cutToLayer(); this.hide(); };
        var delBtn  = _btn('Erase', '#2a1a1a', '#ff7766');
        delBtn.style.flex = '0 0 auto';
        delBtn.title = 'Delete the selected pixels (transparent / background color)';
        delBtn.onclick = () => { this.tool.deleteSelection(); this.hide(); };
        classicRow.appendChild(copyBtn);
        classicRow.appendChild(cutBtn);
        classicRow.appendChild(delBtn);
        panel.appendChild(classicRow);

        document.body.appendChild(panel);
        this._panel = panel;

        this._escHandler = (e) => { if (e.key === 'Escape') this.hide(); };
        document.addEventListener('keydown', this._escHandler);
    }

    hide() {
        if (this._panel) { this._panel.remove(); this._panel = null; }
        if (this._escHandler) {
            document.removeEventListener('keydown', this._escHandler);
            this._escHandler = null;
        }
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    async _scaleSelection(scalePct) {
        if (!this._check()) return;
        this.hide();
        showProgress('Scaling object and AI-filling the gap…', 30);
        try {
            var res = await _post('/api/image/scale-selection', {
                image: this._imageData,
                mask:  this._maskData,
                scale_pct: scalePct,
            });
            this.tool.updateLayerWithResult(res.result);
            this.tool.clearSelection();
            hideProgress();
            alertify.success('Scaled by ' + scalePct + '%!');
        } catch (e) {
            hideProgress();
            alertify.error('Scale failed: ' + e.message);
        }
    }

    async _makeAsymmetric() {
        if (!this._check()) return;
        this.hide();
        connectProgressSSE('inpaint', window.API_BASE_URL || '');
        showProgress('AI is adding natural asymmetry…', 60);
        try {
            var res = await _post('/api/image/ai-edit-region', {
                image:          this._imageData,
                mask:           this._maskData,
                instruction:    'natural asymmetry, slight organic variation, realistic, subtle imperfection',
                negative_prompt:'perfectly symmetric, mirror image, artificial, identical halves',
                steps: 30,
                cfg_scale: 7.5,
            });
            this.tool.updateLayerWithResult(res.result);
            this.tool.clearSelection();
            disconnectProgressSSE();
            hideProgress();
            alertify.success('Made less symmetrical!');
        } catch (e) {
            disconnectProgressSSE();
            hideProgress();
            alertify.error('AI edit failed: ' + e.message);
        }
    }

    async _aiEditRegion(instruction) {
        if (!this._check()) return;
        this.hide();
        connectProgressSSE('inpaint', window.API_BASE_URL || '');
        showProgress('AI is editing the region…', 60);
        try {
            var res = await _post('/api/image/ai-edit-region', {
                image:       this._imageData,
                mask:        this._maskData,
                instruction: instruction,
                steps: 30,
                cfg_scale: 7.5,
            });
            this.tool.updateLayerWithResult(res.result);
            this.tool.clearSelection();
            disconnectProgressSSE();
            hideProgress();
            alertify.success('Done!');
        } catch (e) {
            disconnectProgressSSE();
            hideProgress();
            alertify.error('AI edit failed: ' + e.message);
        }
    }

    async _pasteFromClipboard() {
        if (!this._check()) return;

        if (!navigator.clipboard || !navigator.clipboard.read) {
            alertify.error('Clipboard API not available. Use HTTPS or enable clipboard permissions.');
            return;
        }
        try {
            var items = await navigator.clipboard.read();
            var clipBlob = null;
            for (var item of items) {
                for (var type of item.types) {
                    if (type.startsWith('image/')) {
                        clipBlob = await item.getType(type);
                        break;
                    }
                }
                if (clipBlob) break;
            }
            if (!clipBlob) {
                alertify.error('No image in clipboard. Copy an image first (e.g., right-click → Copy image).');
                return;
            }

            var clipBase64 = await _blobToBase64(clipBlob);
            this.hide();
            showProgress('Pasting clipboard into selection…', 10);

            var res = await _post('/api/image/paste-into-selection', {
                image:       this._imageData,
                mask:        this._maskData,
                paste_image: clipBase64,
            });
            this.tool.updateLayerWithResult(res.result);
            this.tool.clearSelection();
            hideProgress();
            alertify.success('Clipboard pasted into selection!');
        } catch (e) {
            hideProgress();
            alertify.error('Paste failed: ' + e.message);
        }
    }

    async _replaceSubjectFromFile() {
        if (!this._check()) return;

        // Open a file picker — no clipboard API required
        var fileInput = document.createElement('input');
        fileInput.type = 'file';
        fileInput.accept = 'image/*';

        fileInput.onchange = async () => {
            var file = fileInput.files[0];
            if (!file) return;

            var subjectBase64 = await _fileToBase64(file);
            this.hide();
            showProgress('Extracting subject and compositing…', 15);

            try {
                var res = await _post('/api/image/replace-subject', {
                    background_image: this._imageData,
                    subject_image:    subjectBase64,
                    mask:             this._maskData,
                    match_colors:     true,
                });
                this.tool.updateLayerWithResult(res.result);
                this.tool.clearSelection();
                hideProgress();
                alertify.success('Subject replaced with background color matching!');
            } catch (e) {
                hideProgress();
                alertify.error('Replace subject failed: ' + e.message);
            }
        };

        fileInput.click();
    }

    _check() {
        if (!this._imageData || !this._maskData) {
            alertify.error('No selection data. Make a new selection first.');
            return false;
        }
        return true;
    }
}

// ── Shared method: patch into both smart_select and brush_select instances ───

/**
 * Update the active layer canvas with a base64 result image from the backend.
 * Call as `this.updateLayerWithResult(base64)` on any tool that extends Base_tools_class.
 */
export function updateLayerWithResult(base64, tool) {
    var img = new Image();
    img.onload = function () {
        var canvas = document.createElement('canvas');
        canvas.width  = img.width;
        canvas.height = img.height;
        canvas.getContext('2d').drawImage(img, 0, 0);

        app.State.do_action(
            new app.Actions.Bundle_action('ai_transform', 'AI Transform', [
                new app.Actions.Update_layer_image_action(canvas, config.layer.id)
            ])
        );
        // Trigger re-render
        config.need_render = true;
    };
    img.src = 'data:image/png;base64,' + base64;
}

// ── Private helpers ──────────────────────────────────────────────────────────

function _btn(text, bg, color) {
    var b = document.createElement('button');
    b.textContent = text;
    b.style.cssText = 'background:' + bg + ';color:' + color + ';border:1px solid #3a3a6a;padding:4px 10px;border-radius:5px;cursor:pointer;font-size:11px;white-space:nowrap';
    return b;
}

function _actionCard(text, bg, color, description, handler) {
    var wrap = document.createElement('div');
    wrap.style.cssText = 'background:' + bg + ';border-radius:7px;padding:7px 10px;cursor:pointer;border:1px solid transparent';
    wrap.addEventListener('mouseenter', () => { wrap.style.borderColor = color; });
    wrap.addEventListener('mouseleave', () => { wrap.style.borderColor = 'transparent'; });
    wrap.onclick = handler;
    var label = document.createElement('div');
    label.textContent = text;
    label.style.cssText = 'color:' + color + ';font-size:12px;font-weight:500;pointer-events:none';
    var desc = document.createElement('div');
    desc.textContent = description;
    desc.style.cssText = 'color:#5566aa;font-size:10px;margin-top:3px;pointer-events:none';
    wrap.appendChild(label);
    wrap.appendChild(desc);
    return wrap;
}

function _sectionLabel(text) {
    var el = document.createElement('div');
    el.style.cssText = 'font-size:9px;font-weight:bold;letter-spacing:0.08em;color:#555577;text-transform:uppercase;margin-top:2px';
    el.textContent = text;
    return el;
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

function _blobToBase64(blob) {
    return new Promise((resolve, reject) => {
        var reader = new FileReader();
        reader.onload  = (e) => resolve(e.target.result.split(',')[1]);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
    });
}

function _fileToBase64(file) {
    return new Promise((resolve, reject) => {
        var reader = new FileReader();
        reader.onload  = (e) => resolve(e.target.result.split(',')[1]);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
}
