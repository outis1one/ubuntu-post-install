/**
 * Text Presets — insert a styled text layer with one click.
 * Presets: Heading, Subheading, Body, Caption, Quote, Bold Label.
 * Each preset sets font, size, weight, color, and positions on canvas center.
 *
 * Menu target: text/text_presets.add_preset
 */

import app from './../../app.js';
import config from './../../config.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

const PRESETS = [
    {
        label: 'Heading',
        sample: 'Add a heading',
        family: 'Montserrat', size: 72, bold: true, italic: false,
        fill_color: '#ffffff', stroke_size: 0,
    },
    {
        label: 'Subheading',
        sample: 'Add a subheading',
        family: 'Montserrat', size: 44, bold: false, italic: false,
        fill_color: '#e2e8f0', stroke_size: 0,
    },
    {
        label: 'Body',
        sample: 'Add body text',
        family: 'Lato', size: 28, bold: false, italic: false,
        fill_color: '#cbd5e1', stroke_size: 0,
    },
    {
        label: 'Caption',
        sample: 'Add a caption',
        family: 'Lato', size: 20, bold: false, italic: true,
        fill_color: '#94a3b8', stroke_size: 0,
    },
    {
        label: 'Quote',
        sample: '"Add a quote"',
        family: 'Playfair Display', size: 36, bold: false, italic: true,
        fill_color: '#f1f5f9', stroke_size: 0,
    },
    {
        label: 'Bold Label',
        sample: 'LABEL',
        family: 'Oswald', size: 32, bold: true, italic: false,
        fill_color: '#ffffff', stroke_size: 2, stroke_color: '#000000',
    },
];

class Text_presets_class {
    constructor() {
        if (instance) return instance;
        instance = this;
        this.Dialog = new Dialog_class();
    }

    add_preset() {
        var _this = this;
        const labels = PRESETS.map(p => p.label);

        this.Dialog.show({
            title: 'Add Text',
            params: [
                {
                    title: '',
                    html: `<div style="display:flex;flex-direction:column;gap:6px;margin-bottom:4px;">
                        ${PRESETS.map((p, i) => `
                        <div data-preset-idx="${i}" style="padding:8px 12px;border-radius:8px;
                            border:1px solid #333;cursor:pointer;transition:background .12s;"
                            onmouseover="this.style.background='#2a2a2a'"
                            onmouseout="this.style.background='transparent'">
                            <span style="font-family:${p.family},sans-serif;font-size:${Math.min(p.size * 0.4, 22)}px;
                                         font-weight:${p.bold ? 'bold' : 'normal'};
                                         font-style:${p.italic ? 'italic' : 'normal'};
                                         color:${p.fill_color};">${p.sample}</span>
                            <span style="float:right;font-size:10px;color:#555;">${p.family} · ${p.size}px</span>
                        </div>`).join('')}
                    </div>`,
                },
                {
                    name: 'custom_text',
                    title: 'Custom text (optional):',
                    value: '',
                },
            ],
            on_finish: async function (params) {
                // Detect which preset was last hovered/clicked — use dialog value instead
                const label = params.preset || labels[0];
                // Because we can't easily get the clicked row from the html block,
                // use the first preset as default. The user can also type a custom text.
                // A nicer approach: wire click handlers after dialog renders.
                _this._applyPreset(PRESETS[0], params.custom_text || '');
            },
        });

        // Wire preset row clicks after the dialog is in DOM
        requestAnimationFrame(() => {
            document.querySelectorAll('[data-preset-idx]').forEach(el => {
                el.addEventListener('click', () => {
                    const idx = parseInt(el.dataset.presetIdx, 10);
                    const customInput = document.querySelector('input[name="custom_text"]') ||
                                        document.querySelector('#custom_text');
                    const text = customInput ? customInput.value.trim() : '';
                    _this._applyPreset(PRESETS[idx], text);
                    // Close dialog
                    const closeBtn = document.querySelector('.dialog_close') ||
                                     document.querySelector('[data-dialog-close]');
                    if (closeBtn) closeBtn.click();
                });
            });
        });
    }

    _applyPreset(preset, customText) {
        const text    = customText || preset.sample;
        const cw      = config.WIDTH  || 800;
        const ch      = config.HEIGHT || 600;

        // Build a text layer. miniPaint text layers use type='text' with params.
        app.State.do_action(
            new app.Actions.Insert_layer_action({
                type:   'text',
                name:   preset.label,
                x:      Math.round(cw * 0.1),
                y:      Math.round(ch * 0.4),
                width:  Math.round(cw * 0.8),
                height: preset.size + 20,
                width_original:  Math.round(cw * 0.8),
                height_original: preset.size + 20,
                params: {
                    text:   text,
                    family: preset.family,
                    size:   preset.size,
                    bold:   preset.bold,
                    italic: preset.italic,
                    fill_color:   preset.fill_color,
                    stroke_size:  preset.stroke_size || 0,
                    stroke_color: preset.stroke_color || '#000000',
                    kerning: 0,
                    leading: 0,
                },
            })
        );
        alertify.success(`"${preset.label}" text added — double-click to edit.`);
    }
}

export default Text_presets_class;
