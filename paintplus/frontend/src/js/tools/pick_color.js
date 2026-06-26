/**
 * Pick Color (Eyedropper) — enhanced with live color tooltip.
 *
 * Hover: floating tooltip shows hex, RGB, HSL, and nearest Pantone match with ΔE.
 * Click: sets as active color AND copies hex to clipboard.
 * Drag: continuously samples color while dragging.
 *
 * ΔE (Delta E) is the color difference between the sampled color and the
 * nearest Pantone ink. Lower is better:
 *   < 2  = Excellent — nearly identical in print
 *   2–5  = Good — slight difference, acceptable for most print work
 *   5–10 = Fair — noticeable difference; specify Pantone manually if color accuracy matters
 *   > 10 = Poor — this color cannot be faithfully reproduced as a single Pantone ink
 */

import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Helper_class from './../libs/helpers.js';
import Base_gui_class from './../core/base-gui.js';
import { hexToRgb, rgbToHsl, rgbToLab, nearestPantone, deltaEBadge } from './../libs/color_utils.js';

class Pick_color_class extends Base_tools_class {

    constructor(ctx) {
        super();
        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.Base_gui = new Base_gui_class();
        this.ctx = ctx;
        this.name = 'pick_color';
        this._tooltip = null;
        this._lastHex = null;
    }

    dragStart(event) {
        if (config.TOOL.name !== this.name) return;
        this.mousedown(event);
    }

    dragMove(event) {
        if (config.TOOL.name !== this.name) return;
        this.mousemove(event);
    }

    load() {
        var _this = this;

        document.addEventListener('mousedown', e => _this.dragStart(e));
        document.addEventListener('mousemove', e => {
            if (config.TOOL.name !== _this.name) { _this._hideTooltip(); return; }
            _this.dragMove(e);
        });
        document.addEventListener('mouseup', e => {
            if (config.TOOL.name !== _this.name) return;
            var mouse = _this.get_mouse_info(e);
            if (mouse.click_valid) _this.copy_color_to_clipboard();
        });
        document.addEventListener('touchstart', e => _this.dragStart(e));
        document.addEventListener('touchmove',  e => _this.dragMove(e));
        document.addEventListener('mouseleave', () => _this._hideTooltip());
    }

    mousedown(e) {
        var mouse = this.get_mouse_info(e);
        if (!mouse.click_valid) return;
        this.pick_color(mouse);
    }

    mousemove(e) {
        var mouse = this.get_mouse_info(e);
        // Show tooltip on hover (even without drag)
        this._sampleAndTooltip(mouse, e.clientX, e.clientY);
        if (!mouse.is_drag || !mouse.click_valid) return;
        this.pick_color(mouse);
    }

    pick_color(mouse) {
        var params = this.getParams();
        var canvas, ctx;
        if (!params.global) {
            canvas = this.Base_layers.convert_layer_to_canvas(config.layer.id, null, false);
            ctx    = canvas.getContext('2d');
        } else {
            canvas = document.createElement('canvas');
            ctx    = canvas.getContext('2d');
            canvas.width  = config.WIDTH;
            canvas.height = config.HEIGHT;
            this.Base_layers.convert_layers_to_canvas(ctx, null, false);
        }

        var c   = ctx.getImageData(mouse.x, mouse.y, 1, 1).data;
        var hex = this.Helper.rgbToHex(c[0], c[1], c[2]);

        const def = { hex };
        if (c[3] > 0) def.a = c[3];
        this.Base_gui.GUI_colors.set_color(def);
        this._lastHex = hex;
    }

    copy_color_to_clipboard() {
        navigator.clipboard.writeText(config.COLOR).catch(() => {});
    }

    // ── Tooltip ────────────────────────────────────────────────────────────────

    _sampleAndTooltip(mouse, clientX, clientY) {
        if (!config.layer || !mouse.click_valid) { this._hideTooltip(); return; }

        var params = this.getParams();
        var canvas, ctx;
        try {
            if (!params.global) {
                canvas = this.Base_layers.convert_layer_to_canvas(config.layer.id, null, false);
                ctx    = canvas.getContext('2d');
            } else {
                canvas = document.createElement('canvas');
                ctx    = canvas.getContext('2d');
                canvas.width  = config.WIDTH;
                canvas.height = config.HEIGHT;
                this.Base_layers.convert_layers_to_canvas(ctx, null, false);
            }
        } catch { this._hideTooltip(); return; }

        var c   = ctx.getImageData(mouse.x, mouse.y, 1, 1).data;
        var r = c[0], g = c[1], b = c[2], a = c[3];
        if (a === 0) { this._hideTooltip(); return; }

        var hex = this.Helper.rgbToHex(r, g, b);
        this._showTooltip(hex, r, g, b, clientX, clientY);
    }

    _showTooltip(hex, r, g, b, cx, cy) {
        const hsl     = rgbToHsl(r, g, b);
        const pantone = nearestPantone(hex);
        const badge   = deltaEBadge(pantone.quality);

        // Perceived text color for swatch
        const brightness = 0.299 * r + 0.587 * g + 0.114 * b;
        const swatchText = brightness > 140 ? '#1a1a1a' : '#ffffff';

        if (!this._tooltip) {
            const t = document.createElement('div');
            t.id = 'pick_color_tooltip';
            Object.assign(t.style, {
                position:     'fixed',
                zIndex:       '99999',
                background:   '#1a1a1a',
                border:       '1px solid #3a3a3a',
                borderRadius: '10px',
                padding:      '10px 13px',
                fontFamily:   'monospace, sans-serif',
                fontSize:     '12px',
                color:        '#ddd',
                pointerEvents:'none',
                boxShadow:    '0 4px 16px rgba(0,0,0,0.6)',
                minWidth:     '210px',
                lineHeight:   '1.6',
            });
            document.body.appendChild(t);
            this._tooltip = t;
        }

        const t = this._tooltip;

        t.innerHTML = `
            <div style="display:flex;align-items:center;gap:10px;margin-bottom:8px;">
                <div style="width:40px;height:40px;border-radius:7px;background:${hex};
                            border:1px solid #444;flex-shrink:0;display:flex;align-items:center;
                            justify-content:center;font-size:10px;color:${swatchText};">
                </div>
                <div>
                    <div style="font-size:15px;font-weight:bold;letter-spacing:1px;">${hex.toUpperCase()}</div>
                    <div style="color:#888;font-size:11px;">rgb(${r}, ${g}, ${b})</div>
                    <div style="color:#888;font-size:11px;">hsl(${hsl.h}°, ${hsl.s}%, ${hsl.l}%)</div>
                </div>
            </div>
            <div style="border-top:1px solid #2e2e2e;padding-top:7px;">
                <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;">
                    <div style="width:16px;height:16px;border-radius:4px;background:${pantone.hex};
                                border:1px solid #444;flex-shrink:0;"></div>
                    <span style="color:#ccc;font-size:11px;">${pantone.name}</span>
                </div>
                <div style="display:flex;align-items:center;gap:6px;font-size:11px;">
                    <span style="color:#666;">ΔE ${pantone.deltaE}</span>
                    <span style="color:${badge.color};">● ${badge.label}</span>
                </div>
                ${pantone.quality === 'poor'
                    ? `<div style="color:#f87171;font-size:10px;margin-top:3px;">
                           Tip: this color may shift significantly in print.
                       </div>`
                    : ''}
            </div>
            <div style="color:#555;font-size:10px;margin-top:7px;">Click to copy hex & set active color</div>`;

        // Position tooltip near cursor, keep on screen
        const tw = 230, th = 160;
        let tx = cx + 16, ty = cy + 16;
        if (tx + tw > window.innerWidth  - 8) tx = cx - tw - 8;
        if (ty + th > window.innerHeight - 8) ty = cy - th - 8;
        t.style.left = tx + 'px';
        t.style.top  = ty + 'px';
        t.style.display = 'block';
    }

    _hideTooltip() {
        if (this._tooltip) this._tooltip.style.display = 'none';
    }
}

export default Pick_color_class;
