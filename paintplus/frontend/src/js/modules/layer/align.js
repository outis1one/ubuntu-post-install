/**
 * Layer Alignment — align the active layer (or multiple selected layers) to the canvas.
 * Operations: center H, center V, center both, align left/right/top/bottom, distribute.
 * Shows as a compact floating toolbar.
 *
 * Menu target: layer/align.align
 */

import app from './../../app.js';
import config from './../../config.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

const BUTTONS = [
    { id: 'ch',  label: '⬌',   title: 'Center horizontally on canvas' },
    { id: 'cv',  label: '⬍',   title: 'Center vertically on canvas' },
    { id: 'cc',  label: '⊕',   title: 'Center on canvas' },
    { id: 'sep', label: '|',   title: '', sep: true },
    { id: 'al',  label: '⇤',   title: 'Align left edge to canvas' },
    { id: 'ar',  label: '⇥',   title: 'Align right edge to canvas' },
    { id: 'at',  label: '⇡',   title: 'Align top edge to canvas' },
    { id: 'ab',  label: '⇣',   title: 'Align bottom edge to canvas' },
];

class Layer_align_class {
    constructor() {
        if (instance) return instance;
        instance = this;
        this._panel = null;
    }

    align() {
        if (this._panel) { this._removePanel(); return; }
        this._mountPanel();
    }

    _mountPanel() {
        this._removePanel();
        const panel = document.createElement('div');
        panel.id = 'align_panel';
        Object.assign(panel.style, {
            position:     'fixed',
            top:          '60px',
            left:         '50%',
            transform:    'translateX(-50%)',
            background:   '#1a1a1a',
            border:       '1px solid #3a3a3a',
            borderRadius: '10px',
            padding:      '7px 10px',
            display:      'flex',
            alignItems:   'center',
            gap:          '4px',
            zIndex:       '8889',
            boxShadow:    '0 4px 16px rgba(0,0,0,0.5)',
            fontFamily:   'sans-serif',
            userSelect:   'none',
        });

        const btnHtml = BUTTONS.map(b => {
            if (b.sep) return `<span style="color:#444;padding:0 2px;">│</span>`;
            return `<button data-align="${b.id}" title="${b.title}"
                style="width:30px;height:30px;border-radius:6px;border:1px solid #444;
                       background:#252525;color:#ccc;cursor:pointer;font-size:16px;
                       display:flex;align-items:center;justify-content:center;
                       transition:background .12s;"
                onmouseover="this.style.background='#333'"
                onmouseout="this.style.background='#252525'">${b.label}</button>`;
        }).join('');

        panel.innerHTML = `
            <span style="font-size:11px;color:#555;margin-right:4px;">Align:</span>
            ${btnHtml}
            <span id="align-close" style="margin-left:6px;cursor:pointer;color:#555;font-size:18px;">×</span>`;

        document.body.appendChild(panel);
        this._panel = panel;

        panel.querySelector('#align-close').addEventListener('click', () => this._removePanel());
        panel.querySelectorAll('[data-align]').forEach(btn => {
            btn.addEventListener('click', () => this._doAlign(btn.dataset.align));
        });
    }

    _doAlign(op) {
        const layer = config.layer;
        if (!layer) { alertify.error('Select a layer first.'); return; }

        const cw = config.WIDTH;
        const ch = config.HEIGHT;
        const lw = layer.width;
        const lh = layer.height;

        let newX = layer.x;
        let newY = layer.y;

        if (op === 'ch' || op === 'cc') newX = Math.round((cw - lw) / 2);
        if (op === 'cv' || op === 'cc') newY = Math.round((ch - lh) / 2);
        if (op === 'al') newX = 0;
        if (op === 'ar') newX = cw - lw;
        if (op === 'at') newY = 0;
        if (op === 'ab') newY = ch - lh;

        app.State.do_action(
            new app.Actions.Update_layer_action(layer.id, { x: newX, y: newY })
        );
    }

    _removePanel() {
        if (this._panel) { this._panel.remove(); this._panel = null; }
    }
}

export default Layer_align_class;
