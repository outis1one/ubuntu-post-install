/**
 * Color Palette Extractor — pull dominant colors from the current image layer.
 * Shows a floating swatch panel; click a swatch to copy the hex or set as active color.
 *
 * Menu target: image/color_palette.color_palette
 */

import config from './../../config.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

class Image_color_palette_class {
    constructor() {
        if (instance) return instance;
        instance = this;
        this._panel = null;
    }

    async color_palette() {
        if (!config.layer || config.layer.type !== 'image') {
            alertify.error('Select an image layer first.');
            return;
        }
        // Toggle: if panel already showing, close it
        if (this._panel) { this._removePanel(); return; }

        alertify.message('Extracting colors…', 0);
        try {
            const layer = config.layer;
            const c = document.createElement('canvas');
            c.width = layer.width_original; c.height = layer.height_original;
            c.getContext('2d').drawImage(layer.link, 0, 0);
            const imageB64 = c.toDataURL('image/png').split(',')[1];

            const base = window.API_BASE_URL || '';
            const r = await fetch(`${base}/api/extract-colors`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ image: imageB64, count: 8 }),
            });
            if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || 'Failed');
            const data = await r.json();

            alertify.dismissAll();
            this._showPanel(data.colors);
        } catch (err) {
            alertify.dismissAll();
            alertify.error('Color extraction failed: ' + (err.message || err));
        }
    }

    _showPanel(colors) {
        this._removePanel();
        const panel = document.createElement('div');
        panel.id = 'color_palette_panel';
        Object.assign(panel.style, {
            position: 'fixed', bottom: '72px', right: '24px',
            background: '#1a1a1a', border: '1px solid #3a3a3a',
            borderRadius: '12px', padding: '12px 14px',
            zIndex: '9998', boxShadow: '0 6px 24px rgba(0,0,0,0.6)',
            fontFamily: 'sans-serif', fontSize: '12px', color: '#bbb',
            userSelect: 'none', minWidth: '180px',
        });

        const swatchesHtml = colors.map(hex => `
            <div title="Click to copy  •  Shift+click to set active color"
                 data-hex="${hex}"
                 style="display:inline-block;width:32px;height:32px;border-radius:6px;
                        background:${hex};cursor:pointer;border:2px solid transparent;
                        transition:border-color .12s;margin:2px;"
                 onmouseover="this.style.borderColor='#fff'"
                 onmouseout="this.style.borderColor='transparent'">
            </div>`).join('');

        panel.innerHTML = `
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
                <span style="font-size:12px;color:#888;">Image Palette</span>
                <span id="cp-close" style="cursor:pointer;color:#666;font-size:16px;line-height:1;">×</span>
            </div>
            <div style="display:flex;flex-wrap:wrap;gap:2px;">${swatchesHtml}</div>
            <div id="cp-copied" style="font-size:11px;color:#4ade80;margin-top:6px;min-height:14px;"></div>
            <div style="font-size:10px;color:#555;margin-top:4px;">Click: copy hex · Shift+click: set color</div>`;

        document.body.appendChild(panel);
        this._panel = panel;

        // Close button
        panel.querySelector('#cp-close').addEventListener('click', () => this._removePanel());

        // Swatch clicks
        panel.querySelectorAll('[data-hex]').forEach(el => {
            el.addEventListener('click', e => {
                const hex = el.dataset.hex;
                if (e.shiftKey) {
                    // Set as active color in miniPaint
                    config.COLOR = hex;
                    const copiedEl = panel.querySelector('#cp-copied');
                    if (copiedEl) copiedEl.textContent = `Active color set to ${hex}`;
                } else {
                    navigator.clipboard.writeText(hex).catch(() => {});
                    const copiedEl = panel.querySelector('#cp-copied');
                    if (copiedEl) { copiedEl.textContent = `Copied ${hex}`; }
                }
            });
        });
    }

    _removePanel() {
        if (this._panel) { this._panel.remove(); this._panel = null; }
    }
}

export default Image_color_palette_class;
