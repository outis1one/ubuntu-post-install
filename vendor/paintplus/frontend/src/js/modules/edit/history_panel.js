/**
 * History Panel — visual undo history timeline.
 * Shows the last N actions as a clickable list. Click any item to undo/redo to that point.
 * Docks as a floating panel on the right side of the screen.
 *
 * Menu target: edit/history_panel.toggle
 */

import app from './../../app.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

class Edit_history_panel_class {
    constructor() {
        if (instance) return instance;
        instance = this;
        this._panel = null;
        this._interval = null;
    }

    toggle() {
        if (this._panel) {
            this._stop();
        } else {
            this._start();
        }
    }

    _start() {
        this._buildPanel();
        this._render();
        // Refresh whenever the history changes (poll lightly)
        this._interval = setInterval(() => this._render(), 800);
    }

    _stop() {
        if (this._interval) { clearInterval(this._interval); this._interval = null; }
        if (this._panel)    { this._panel.remove(); this._panel = null; }
    }

    _buildPanel() {
        const panel = document.createElement('div');
        panel.id = 'history_panel';
        Object.assign(panel.style, {
            position:     'fixed',
            top:          '60px',
            right:        '0',
            width:        '200px',
            maxHeight:    'calc(100vh - 80px)',
            overflowY:    'auto',
            background:   '#1a1a1a',
            borderLeft:   '1px solid #333',
            borderBottom: '1px solid #333',
            borderRadius: '0 0 0 10px',
            zIndex:       '8888',
            fontFamily:   'sans-serif',
            fontSize:     '12px',
            color:        '#ccc',
            boxShadow:    '-4px 4px 16px rgba(0,0,0,0.4)',
            userSelect:   'none',
        });
        panel.innerHTML = `
            <div style="display:flex;justify-content:space-between;align-items:center;
                        padding:8px 10px;border-bottom:1px solid #333;position:sticky;top:0;
                        background:#1a1a1a;z-index:1;">
                <span style="font-size:12px;color:#888;font-weight:600;">History</span>
                <span id="hist-close" style="cursor:pointer;color:#555;font-size:16px;">×</span>
            </div>
            <div id="hist-list"></div>`;
        document.body.appendChild(panel);
        this._panel = panel;
        panel.querySelector('#hist-close').addEventListener('click', () => this._stop());
    }

    _render() {
        if (!this._panel) return;
        const list = this._panel.querySelector('#hist-list');
        if (!list) return;

        const history = app.State.action_history || [];
        const idx     = app.State.action_history_index ?? history.length;

        if (history.length === 0) {
            list.innerHTML = `<div style="padding:12px 10px;color:#555;">No actions yet.</div>`;
            return;
        }

        // Build rows newest-first
        const rows = [];
        // "Current state" row at top
        const atTop = idx >= history.length;
        rows.push(`<div data-idx="${history.length}"
            style="padding:6px 10px;cursor:pointer;border-bottom:1px solid #222;
                   background:${atTop ? '#1e3a5f' : 'transparent'};
                   color:${atTop ? '#93c5fd' : '#666'};"
            >
            <span style="margin-right:6px;font-size:10px;">${atTop ? '▶' : '○'}</span>Current state
        </div>`);

        for (let i = history.length - 1; i >= 0; i--) {
            const action  = history[i];
            const isCurrent = (i === idx - 1);
            const isFuture  = (i >= idx);
            const label   = action.action_description || action.action_id || `Step ${i + 1}`;
            rows.push(`<div data-idx="${i}"
                style="padding:6px 10px;cursor:pointer;border-bottom:1px solid #1e1e1e;
                       background:${isCurrent ? '#1e3a5f' : 'transparent'};
                       color:${isFuture ? '#444' : isCurrent ? '#93c5fd' : '#ccc'};"
                >
                <span style="margin-right:6px;font-size:10px;">${isCurrent ? '▶' : isFuture ? '○' : '·'}</span>${_escHtml(label)}
            </div>`);
        }
        list.innerHTML = rows.join('');

        // Wire clicks
        list.querySelectorAll('[data-idx]').forEach(el => {
            el.addEventListener('click', () => {
                const target = parseInt(el.dataset.idx, 10);
                this._jumpTo(target);
            });
        });
    }

    _jumpTo(targetIdx) {
        const history = app.State.action_history || [];
        const current = app.State.action_history_index ?? history.length;

        if (targetIdx === current) return;

        const steps = targetIdx - current;
        if (steps > 0) {
            for (let i = 0; i < steps; i++) app.State.redo_action();
        } else {
            for (let i = 0; i < Math.abs(steps); i++) app.State.undo_action();
        }
        this._render();
    }
}

function _escHtml(s) {
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

export default Edit_history_panel_class;
