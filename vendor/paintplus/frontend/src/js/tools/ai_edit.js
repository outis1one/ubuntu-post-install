/**
 * AI Edit — unified smart selection + inpainting tool.
 *
 * Workflow:
 *   1. CLICK mode (default): click any object → SAM auto-selects it (red overlay)
 *      • Alt+click → subtract from selection (deselect over-selected area)
 *      • Multiple clicks accumulate on the mask
 *   2. BRUSH + / BRUSH − tabs: paint to add or erase from the mask by hand
 *      (refine what SAM missed or got wrong)
 *   3. Action bar: Erase | Replace… | Upscale | Expand | Clear
 *
 * SAM model (~375 MB) auto-downloads on first click; progress shown inline.
 * Falls back gracefully to brush-only if SAM is unavailable.
 */

import app from './../app.js';
import config from './../config.js';
import Base_layers_class from './../core/base-layers.js';
import Base_tools_class from './../core/base-tools.js';
import alertify from './../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

const BRUSH_DEFAULT = 30;
const OVERLAY_COLOR = 'rgba(255, 55, 55, 0.50)';

class Tools_ai_edit_class extends Base_tools_class {

    constructor() {
        super();
        if (instance) return instance;
        instance = this;
        this.Base_layers  = new Base_layers_class();
        this.name         = 'ai_edit';
        this.title        = 'AI Edit';
        // interaction state
        this._mode        = 'sam';    // 'sam' | 'brush_add' | 'brush_sub'
        this._painting    = false;
        this._samWorking  = false;
        this._isRunning   = false;
        this._hasMask     = false;
        // DOM elements
        this._maskCanvas  = null;
        this._maskCtx     = null;
        this._overlayEl   = null;
        this._panel       = null;
    }

    // ── Tool lifecycle ────────────────────────────────────────────────────────

    load() {
        this.default_events();
    }

    on_activate() {
        if (!config.layer || config.layer.type !== 'image') {
            alertify.error('Select an image layer first.');
            return;
        }
        this._initMask();
        this._mountOverlay();
        this._mountPanel();
    }

    on_leave() {
        this._removeOverlay();
        this._removePanel();
        this._painting = false;
    }

    // ── Input routing ─────────────────────────────────────────────────────────

    mousedown(e) {
        if (config.TOOL.name !== this.name) return;
        var mouse = this.get_mouse_info(e);
        if (!mouse.click_valid) return;
        if (!config.layer || config.layer.type !== 'image') return;
        if (this._mode === 'sam') {
            this._handleSamClick(e, mouse);
        } else {
            this._painting = true;
            this._brushPaint(mouse);
        }
    }

    mousemove(e) {
        if (config.TOOL.name !== this.name) return;
        if (this._mode !== 'sam' && this._painting) {
            var mouse = this.get_mouse_info(e);
            if (mouse.is_drag) this._brushPaint(mouse);
        }
    }

    mouseup(e) {
        if (config.TOOL.name !== this.name) return;
        if (this._painting) {
            this._painting = false;
            if (this._hasMask) this._showActions();
        }
    }

    // ── Coordinate mapping — uses miniPaint's get_mouse_info ─────────────────
    // get_mouse_info returns { x, y } already in canvas/layer coordinates.
    // We still need to know the display scale to size brush strokes on the overlay.

    _mouseToImage(mouse) {
        // mouse.x/y are already in original image coords from get_mouse_info
        const scaleX = (config.WIDTH  * config.ZOOM) / config.layer.width_original;
        const scaleY = (config.HEIGHT * config.ZOOM) / config.layer.height_original;
        return { ix: mouse.x, iy: mouse.y, scaleX, scaleY };
    }

    // ── SAM click selection ───────────────────────────────────────────────────

    async _handleSamClick(e, mouse) {
        if (this._samWorking) return;
        const coords = this._mouseToImage(mouse);

        const label = e.altKey ? 0 : 1;   // alt = exclude, normal = include
        const x = Math.round(coords.ix);
        const y = Math.round(coords.iy);

        // Clamp to image bounds
        const w = config.layer.width_original;
        const h = config.layer.height_original;
        if (x < 0 || y < 0 || x >= w || y >= h) return;

        this._samWorking = true;
        this._setSamCursor('wait');

        // Collect any existing points for multi-click accumulation
        if (!this._samPoints) this._samPoints = [];
        if (!this._samLabels) this._samLabels = [];
        this._samPoints.push([x, y]);
        this._samLabels.push(label);

        try {
            const imageB64 = this._getLayerB64();
            const base = window.API_BASE_URL || '';
            const r = await fetch(`${base}/api/segment/point`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    image:  imageB64,
                    points: this._samPoints,
                    labels: this._samLabels,
                }),
            });

            if (r.status === 503) {
                // SAM model downloading — poll and retry
                const data = await r.json().catch(() => ({}));
                await this._waitForSamModel(data.detail || '');
                // Remove the point we just added so user can retry cleanly
                this._samPoints.pop();
                this._samLabels.pop();
                this._samWorking = false;
                this._setSamCursor('crosshair');
                return;
            }

            if (!r.ok) {
                const err = await r.json().catch(() => ({}));
                throw new Error(err.detail || 'SAM failed');
            }

            const data = await r.json();
            await this._applySamMask(data.mask, label === 0);
            this._hasMask = true;
            this._showActions();

        } catch (err) {
            alertify.error('SAM failed: ' + (err.message || err));
            // Pop failed point
            this._samPoints.pop();
            this._samLabels.pop();
        }

        this._samWorking = false;
        this._setSamCursor('crosshair');
    }

    async _applySamMask(maskB64, isSubtract) {
        return new Promise((resolve) => {
            const img = new Image();
            img.onload = () => {
                // Draw SAM mask onto our persistent mask canvas
                const tmp = document.createElement('canvas');
                tmp.width  = this._maskCanvas.width;
                tmp.height = this._maskCanvas.height;
                const tctx = tmp.getContext('2d');
                tctx.drawImage(img, 0, 0, tmp.width, tmp.height);

                if (isSubtract) {
                    // Erase mask where SAM says to subtract
                    this._maskCtx.globalCompositeOperation = 'destination-out';
                    this._maskCtx.drawImage(tmp, 0, 0);
                    this._maskCtx.globalCompositeOperation = 'source-over';
                } else {
                    this._maskCtx.drawImage(tmp, 0, 0);
                }
                this._redrawOverlay();
                resolve();
            };
            img.src = 'data:image/png;base64,' + maskB64;
        });
    }

    async _waitForSamModel(detail) {
        // SAM model is downloading — show progress bar and poll
        return new Promise((resolve) => {
            alertify.message(
                `<div>Downloading SAM model (~375 MB)…<br>
                 <progress id="sam-dl-progress" value="0" max="100"
                   style="width:100%;margin-top:6px;"></progress>
                 <span id="sam-dl-pct">0%</span><br>
                 <small style="color:#888">This happens once — click the object again when done.</small>
                 </div>`, 0
            );
            const poll = setInterval(async () => {
                try {
                    const base = window.API_BASE_URL || '';
                    const r = await fetch(`${base}/api/segment/install-status`);
                    if (!r.ok) return;
                    const s = await r.json();
                    const bar = document.getElementById('sam-dl-progress');
                    const pct = document.getElementById('sam-dl-pct');
                    if (bar) bar.value = s.progress || 0;
                    if (pct) pct.textContent = `${s.progress || 0}%`;
                    if (s.state === 'done' || s.model_ready) {
                        clearInterval(poll);
                        alertify.dismissAll();
                        alertify.success('SAM model ready — click the object now.');
                        resolve();
                    } else if (s.state === 'failed') {
                        clearInterval(poll);
                        alertify.dismissAll();
                        alertify.error('SAM model download failed. Use Brush mode instead.');
                        resolve();
                    }
                } catch { /* keep polling */ }
            }, 1500);
        });
    }

    _setSamCursor(cursor) {
        const canvasEl = document.getElementById('canvas_minipaint') || document.querySelector('canvas');
        if (canvasEl) canvasEl.style.cursor = cursor;
    }

    // ── Brush painting ────────────────────────────────────────────────────────

    _brushPaint(mouse) {
        const { ix, iy, scaleX, scaleY } = this._mouseToImage(mouse);
        const r = (config.tools[this.name]?.size ?? BRUSH_DEFAULT) / 2;

        // Paint on mask canvas (image coords)
        this._maskCtx.globalCompositeOperation =
            this._mode === 'brush_sub' ? 'destination-out' : 'source-over';
        this._maskCtx.fillStyle = '#ffffff';
        this._maskCtx.beginPath();
        this._maskCtx.arc(ix, iy, r, 0, Math.PI * 2);
        this._maskCtx.fill();
        this._maskCtx.globalCompositeOperation = 'source-over';

        // Mirror on overlay (display coords)
        const oc  = this._overlayEl;
        if (!oc) return;
        const oct = oc.getContext('2d');
        const ox  = ix * scaleX + config.layer.x * config.ZOOM;
        const oy  = iy * scaleY + config.layer.y * config.ZOOM;
        const or_ = r * scaleX;

        if (this._mode === 'brush_sub') {
            oct.globalCompositeOperation = 'destination-out';
            oct.fillStyle = '#000';
        } else {
            oct.globalCompositeOperation = 'source-over';
            oct.fillStyle = OVERLAY_COLOR;
        }
        oct.beginPath();
        oct.arc(ox, oy, or_, 0, Math.PI * 2);
        oct.fill();
        oct.globalCompositeOperation = 'source-over';

        this._hasMask = true;
    }

    // ── Overlay ───────────────────────────────────────────────────────────────

    _mountOverlay() {
        this._removeOverlay();
        const base = document.getElementById('canvas_minipaint') || document.querySelector('canvas');
        if (!base) return;
        const oc = document.createElement('canvas');
        oc.id     = 'ai_edit_overlay';
        oc.width  = base.offsetWidth;
        oc.height = base.offsetHeight;
        Object.assign(oc.style, {
            position: 'absolute', top: base.offsetTop + 'px', left: base.offsetLeft + 'px',
            pointerEvents: 'none', zIndex: '50',
        });
        base.parentElement.appendChild(oc);
        this._overlayEl = oc;
    }

    _redrawOverlay() {
        if (!this._overlayEl || !this._maskCanvas) return;
        const oc  = this._overlayEl;
        const oct = oc.getContext('2d');
        oct.clearRect(0, 0, oc.width, oc.height);

        // Scale mask to overlay size and tint red
        const tmp = document.createElement('canvas');
        tmp.width  = oc.width;
        tmp.height = oc.height;
        const tctx = tmp.getContext('2d');
        tctx.drawImage(this._maskCanvas, 0, 0, oc.width, oc.height);

        // Multiply white mask pixels → red tint using composite
        oct.globalCompositeOperation = 'source-over';
        oct.fillStyle = OVERLAY_COLOR;
        oct.fillRect(0, 0, oc.width, oc.height);
        oct.globalCompositeOperation = 'destination-in';
        oct.drawImage(tmp, 0, 0);
        oct.globalCompositeOperation = 'source-over';
    }

    _removeOverlay() {
        if (this._overlayEl) { this._overlayEl.remove(); this._overlayEl = null; }
    }

    // ── Panel ─────────────────────────────────────────────────────────────────

    _mountPanel() {
        this._removePanel();
        const panel = document.createElement('div');
        panel.id = 'ai_edit_panel';
        Object.assign(panel.style, {
            position: 'fixed', bottom: '72px', left: '50%', transform: 'translateX(-50%)',
            background: '#1a1a1a', border: '1px solid #3a3a3a', borderRadius: '12px',
            padding: '10px 14px', display: 'flex', flexDirection: 'column',
            gap: '8px', zIndex: '9999', boxShadow: '0 6px 24px rgba(0,0,0,0.6)',
            fontFamily: 'sans-serif', fontSize: '13px', color: '#eee',
            userSelect: 'none', minWidth: '460px',
        });
        panel.innerHTML = this._panelHTML();
        document.body.appendChild(panel);
        this._panel = panel;
        this._wirePanel();
    }

    _panelHTML() {
        return `
        <style>
          .aie-btn {
            padding:5px 12px;border-radius:7px;border:1px solid #444;
            background:#252525;color:#ddd;cursor:pointer;font-size:13px;
            transition:background .12s,border-color .12s;white-space:nowrap;
          }
          .aie-btn:hover { background:#333; }
          .aie-btn.active { background:#1e3a5f;border-color:#3b82f6;color:#93c5fd; }
          .aie-btn--go    { background:#2563eb;border-color:#3b82f6;color:#fff; }
          .aie-btn--go:hover { background:#1d4ed8; }
          .aie-btn--danger { border-color:#5a1a1a;color:#f87171; }
          .aie-btn--danger:hover { background:#2a1010; }
          .aie-divider { width:1px;background:#3a3a3a;align-self:stretch; }
        </style>

        <!-- Row 1: mode selector -->
        <div style="display:flex;align-items:center;gap:6px;">
          <span style="color:#666;font-size:11px;margin-right:2px;">Select:</span>
          <button class="aie-btn active" data-mode="sam"       title="Click any object — SAM auto-selects it">✦ Click</button>
          <button class="aie-btn"        data-mode="brush_add" title="Paint to add to selection">＋ Brush</button>
          <button class="aie-btn"        data-mode="brush_sub" title="Paint to remove from selection">− Brush</button>
          <div class="aie-divider"></div>
          <span style="color:#555;font-size:11px;flex:1;" id="aie-hint">Click an object to select it. Alt+click to deselect.</span>
        </div>

        <!-- Row 2: actions -->
        <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
          <span style="color:#666;font-size:11px;margin-right:2px;">Then:</span>
          <button class="aie-btn" data-action="erase">✕ Erase</button>
          <div id="aie-replace-wrap" style="display:flex;align-items:center;gap:6px;">
            <button class="aie-btn aie-btn--go" data-action="replace">✦ Replace</button>
            <input id="aie-prompt" type="text"
              placeholder="make her smile  /  replace with a wolf…"
              style="display:none;width:290px;padding:5px 9px;border-radius:7px;
                     border:1px solid #444;background:#222;color:#eee;font-size:13px;outline:none;" />
            <button id="aie-go" class="aie-btn aie-btn--go" style="display:none;">Go →</button>
          </div>
          <button class="aie-btn" data-action="upscale">⬆ Upscale</button>
          <button class="aie-btn" data-action="expand">↔ Expand</button>
          <button class="aie-btn aie-btn--danger" data-action="clear">↺ Clear</button>
        </div>`;
    }

    _showActions() {
        // No-op — actions are always visible; just a hook for future animation
    }

    _wirePanel() {
        if (!this._panel) return;
        const _this = this;
        const hints = {
            sam:       'Click an object to select it. Alt+click to deselect an area.',
            brush_add: 'Paint over areas to add them to the selection.',
            brush_sub: 'Paint over areas to remove them from the selection.',
        };

        // Mode buttons
        this._panel.querySelectorAll('[data-mode]').forEach(btn => {
            btn.addEventListener('click', () => {
                _this._mode = btn.dataset.mode;
                _this._panel.querySelectorAll('[data-mode]').forEach(b =>
                    b.classList.toggle('active', b === btn));
                const hint = _this._panel.querySelector('#aie-hint');
                if (hint) hint.textContent = hints[_this._mode] || '';
                _this._setSamCursor(_this._mode === 'sam' ? 'crosshair' : 'cell');
            });
        });

        // Action buttons
        this._panel.querySelectorAll('[data-action]').forEach(btn => {
            btn.addEventListener('click', () => {
                const a = btn.dataset.action;
                if (a === 'erase')   _this._doErase();
                if (a === 'replace') _this._toggleReplace();
                if (a === 'upscale') _this._doUpscale();
                if (a === 'expand')  _this._doExpand();
                if (a === 'clear')   _this._doClear();
            });
        });

        // Replace prompt
        const goBtn    = this._panel.querySelector('#aie-go');
        const promptEl = this._panel.querySelector('#aie-prompt');
        if (goBtn && promptEl) {
            goBtn.addEventListener('click', () => _this._doReplace(promptEl.value.trim()));
            promptEl.addEventListener('keydown', e => {
                if (e.key === 'Enter') _this._doReplace(promptEl.value.trim());
            });
        }
    }

    _toggleReplace() {
        const p = this._panel;
        if (!p) return;
        const promptEl = p.querySelector('#aie-prompt');
        const goBtn    = p.querySelector('#aie-go');
        const shown    = promptEl.style.display !== 'none';
        promptEl.style.display = shown ? 'none' : 'inline-block';
        goBtn.style.display    = shown ? 'none' : 'inline-block';
        if (!shown) setTimeout(() => promptEl.focus(), 40);
    }

    _removePanel() {
        if (this._panel) { this._panel.remove(); this._panel = null; }
    }

    // ── Mask + image helpers ──────────────────────────────────────────────────

    _initMask() {
        const w = config.layer.width_original;
        const h = config.layer.height_original;
        this._maskCanvas = document.createElement('canvas');
        this._maskCanvas.width  = w;
        this._maskCanvas.height = h;
        this._maskCtx = this._maskCanvas.getContext('2d');
        this._hasMask = false;
        this._samPoints = [];
        this._samLabels = [];
    }

    _getLayerB64() {
        const layer = config.layer;
        const c = document.createElement('canvas');
        c.width = layer.width_original; c.height = layer.height_original;
        c.getContext('2d').drawImage(layer.link, 0, 0);
        return c.toDataURL('image/png').split(',')[1];
    }

    _requireMask() {
        if (!this._hasMask) {
            alertify.error('Select an area first — click an object or use Brush.');
            return false;
        }
        return true;
    }

    _applyResult(resultB64, label) {
        const img = new Image();
        img.onload = () => {
            const rc = document.createElement('canvas');
            rc.width = img.naturalWidth; rc.height = img.naturalHeight;
            rc.getContext('2d').drawImage(img, 0, 0);
            app.State.do_action(
                new app.Actions.Bundle_action('ai_edit', label, [
                    new app.Actions.Update_layer_image_action(rc)
                ])
            );
            alertify.dismissAll();
            alertify.success(label + ' applied.');
            this._isRunning = false;
            this._doClear();
        };
        img.onerror = () => {
            alertify.dismissAll();
            alertify.error('Failed to load result image.');
            this._isRunning = false;
        };
        img.src = 'data:image/png;base64,' + resultB64;
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    async _doErase() {
        if (!this._requireMask() || this._isRunning) return;
        this._isRunning = true;
        alertify.message('Erasing…', 0);
        try {
            const maskB64 = this._maskCanvas.toDataURL('image/png').split(',')[1];
            const base    = window.API_BASE_URL || '';
            const r = await fetch(`${base}/api/erase`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ image: this._getLayerB64(), mask: maskB64 }),
            });
            if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || 'Failed');
            this._applyResult((await r.json()).result, 'Erase');
        } catch (err) {
            alertify.dismissAll();
            alertify.error('Erase failed: ' + (err.message || err));
            this._isRunning = false;
        }
    }

    async _doReplace(prompt) {
        if (!this._requireMask() || this._isRunning) return;
        if (!prompt) { alertify.error('Describe what you want to put there.'); return; }
        this._isRunning = true;
        alertify.message(`Replacing: "${prompt}"…`, 0);
        try {
            const maskB64 = this._maskCanvas.toDataURL('image/png').split(',')[1];
            const base    = window.API_BASE_URL || '';
            const r = await fetch(`${base}/api/inpaint/remote`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ image: this._getLayerB64(), mask: maskB64, prompt }),
            });
            if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || 'Failed');
            this._applyResult((await r.json()).result, `Replace: ${prompt}`);
        } catch (err) {
            alertify.dismissAll();
            alertify.error('Replace failed: ' + (err.message || err));
            this._isRunning = false;
        }
    }

    _doUpscale() {
        import('./../modules/image/upscale.js').then(m => new m.default().upscale());
    }

    _doExpand() {
        import('./../modules/generate/outpaint.js').then(m => new m.default().outpaint());
    }

    _doClear() {
        if (this._maskCtx)
            this._maskCtx.clearRect(0, 0, this._maskCanvas.width, this._maskCanvas.height);
        if (this._overlayEl)
            this._overlayEl.getContext('2d').clearRect(0, 0, this._overlayEl.width, this._overlayEl.height);
        const p = this._panel;
        if (p) {
            const promptEl = p.querySelector('#aie-prompt');
            const goBtn    = p.querySelector('#aie-go');
            if (promptEl) { promptEl.style.display = 'none'; promptEl.value = ''; }
            if (goBtn)    goBtn.style.display = 'none';
        }
        this._hasMask    = false;
        this._samPoints  = [];
        this._samLabels  = [];
    }
}

export default Tools_ai_edit_class;
