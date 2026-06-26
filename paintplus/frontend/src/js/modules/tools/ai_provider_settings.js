/**
 * AI Provider Settings — configure remote AI provider in-app without editing .env manually.
 * Settings are persisted to localStorage and sent to the backend config endpoint.
 * Menu target: tools/ai_provider_settings.ai_provider_settings
 */

import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import { getCapabilities, getGpuStatus } from './../../api/capabilities.js';

// localStorage key prefix
const LS = 'paintplus_ai_';

function ls_get(key, def = '') {
    return localStorage.getItem(LS + key) ?? def;
}
function ls_set(key, val) {
    localStorage.setItem(LS + key, val);
}

var instance = null;

class Tools_ai_provider_settings_class {

    constructor() {
        if (instance) return instance;
        instance = this;
        this.POP = new Dialog_class();
    }

    async ai_provider_settings() {
        var _this = this;

        // Fetch caps and GPU status in parallel
        var caps = await getCapabilities();
        var gpuStatus = null;
        var local = caps.local || {};
        if (local.local_gpu_available) {
            gpuStatus = await getGpuStatus().catch(() => null);
        }

        var remote = caps.remote || {};
        var statusHtml = remote.provider
            ? (remote.healthy
                ? '<span style="color:#44cc44">● ' + remote.provider + ' — connected</span>'
                : '<span style="color:#ffaa00">● ' + remote.provider + ' — unreachable</span>')
            : '<span style="color:#888">No remote provider configured</span>';

        var gpuInfoHtml = gpuStatus ? _renderGpuInfo(gpuStatus) : '';

        var providerValues = ['', 'openai', 'invokeai', 'comfyui', 'replicate', 'local_gpu'];

        var params = [
            {
                title: 'Status:',
                html: '<div style="margin:4px 0 8px;font-size:12px;">' + statusHtml + '</div>',
            },
        ];

        if (gpuInfoHtml) {
            params.push({
                title: '',
                html: '<div style="margin:4px 0 8px"><div style="font-size:11px;color:#aaa;margin-bottom:3px">Detected GPU:</div>' + gpuInfoHtml + '</div>',
            });
        }

        params.push(
            {
                name: 'provider',
                title: 'Default provider (used unless overridden below):',
                value: ls_get('provider', remote.provider || ''),
                values: providerValues,
                type: 'select',
            },
            // ── Per-operation overrides ───────────────────────────────
            {
                title: '',
                html: '<div style="font-size:11px;color:#888;margin:2px 0 6px;">Per-operation overrides — blank = use default above</div>',
            },
            {
                name: 'provider_inpaint',
                title: 'Inpaint / Replace Selection:',
                value: ls_get('provider_inpaint', remote.overrides?.inpaint || ''),
                values: providerValues,
                type: 'select',
            },
            {
                name: 'provider_txt2img',
                title: 'Text → Image:',
                value: ls_get('provider_txt2img', remote.overrides?.txt2img || ''),
                values: providerValues,
                type: 'select',
            },
            {
                name: 'provider_img2img',
                title: 'Image → Image:',
                value: ls_get('provider_img2img', remote.overrides?.img2img || ''),
                values: providerValues,
                type: 'select',
            },
            {
                name: 'provider_outpaint',
                title: 'Expand Canvas (Outpaint):',
                value: ls_get('provider_outpaint', remote.overrides?.outpaint || ''),
                values: providerValues,
                type: 'select',
            },
            // ── OpenAI ────────────────────────────────────────────────
            {
                name: 'openai_key',
                title: 'OpenAI API key:',
                value: ls_get('openai_key'),
                placeholder: 'sk-...',
            },
            {
                name: 'openai_model',
                title: 'OpenAI model:',
                value: ls_get('openai_model', 'dall-e-3'),
                values: ['dall-e-3', 'dall-e-2'],
                type: 'select',
            },
            // ── InvokeAI ──────────────────────────────────────────────
            {
                name: 'invokeai_url',
                title: 'InvokeAI URL:',
                value: ls_get('invokeai_url'),
                placeholder: 'http://192.168.1.x:9090',
            },
            {
                name: 'invokeai_model',
                title: 'InvokeAI default model:',
                value: ls_get('invokeai_model', 'flux-dev'),
                placeholder: 'flux-dev',
            },
            // ── ComfyUI ───────────────────────────────────────────────
            {
                name: 'comfyui_url',
                title: 'ComfyUI URL:',
                value: ls_get('comfyui_url'),
                placeholder: 'http://192.168.1.x:8188',
            },
            {
                name: 'comfyui_model',
                title: 'ComfyUI default checkpoint:',
                value: ls_get('comfyui_model', 'v1-5-pruned-emaonly.ckpt'),
                placeholder: 'v1-5-pruned-emaonly.ckpt',
            },
            // ── Replicate ─────────────────────────────────────────────
            {
                name: 'replicate_key',
                title: 'Replicate API key:',
                value: ls_get('replicate_key'),
                placeholder: 'r8_...',
            }
        );

        this.POP.show({
            title: 'AI Provider Settings',
            params: params,
            on_finish: async function (params) {
                await _this._save(params);
            },
        });
    }

    async _save(params) {
        // Persist to localStorage
        ls_set('provider',          params.provider || '');
        ls_set('provider_inpaint',  params.provider_inpaint  || '');
        ls_set('provider_txt2img',  params.provider_txt2img  || '');
        ls_set('provider_img2img',  params.provider_img2img  || '');
        ls_set('provider_outpaint', params.provider_outpaint || '');
        ls_set('openai_key',     params.openai_key || '');
        ls_set('openai_model',   params.openai_model || 'dall-e-3');
        ls_set('invokeai_url',   params.invokeai_url || '');
        ls_set('invokeai_model', params.invokeai_model || 'flux-dev');
        ls_set('comfyui_url',    params.comfyui_url || '');
        ls_set('comfyui_model',  params.comfyui_model || 'v1-5-pruned-emaonly.ckpt');
        ls_set('replicate_key',  params.replicate_key || '');

        // Push to backend
        try {
            var payload = {
                ai_provider:              params.provider || '',
                ai_provider_inpaint:      params.provider_inpaint  || '',
                ai_provider_txt2img:      params.provider_txt2img  || '',
                ai_provider_img2img:      params.provider_img2img  || '',
                ai_provider_outpaint:     params.provider_outpaint || '',
                openai_api_key:           params.openai_key || '',
                openai_model:             params.openai_model || 'dall-e-3',
                invokeai_url:             params.invokeai_url || '',
                invokeai_default_model:   params.invokeai_model || 'flux-dev',
                comfyui_url:              params.comfyui_url || '',
                comfyui_default_model:    params.comfyui_model || '',
                replicate_api_key:        params.replicate_key || '',
            };
            var base = window.API_BASE_URL || '';
            var r = await fetch(`${base}/api/config`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
            });

            if (r.ok) {
                alertify.success('AI provider settings saved. Testing connection...');
                var { refreshCapabilities } = await import('./../../api/capabilities.js');
                var caps = await refreshCapabilities();
                if (caps?.remote?.healthy) {
                    alertify.success('Connected to ' + caps.remote.provider + '!');
                } else if (params.provider) {
                    if (params.provider === 'local_gpu') {
                        alertify.success('local_gpu set — restart the container with docker-compose.gpu.yml to activate.');
                    } else {
                        alertify.warning('Settings saved but provider is not reachable. Check URL/key.');
                    }
                }
            } else {
                alertify.warning(
                    'Settings saved locally. To make them permanent, ' +
                    'set these values in your .env file and restart the server.'
                );
            }
        } catch {
            alertify.warning(
                'Settings saved locally. Set AI_PROVIDER and related keys in .env to make permanent.'
            );
        }
    }
}

function _renderGpuInfo(g) {
    var flags = [
        g.fp16 && 'fp16',
        g.bf16 && 'bf16',
        g.fp8  && 'fp8',
        g.int8 && 'int8',
        g.tensor_cores && 'tensor-cores',
        g.xformers && 'xformers',
    ].filter(Boolean).join(' · ');

    var rows = Object.entries(g.recommended || {})
        .filter(([, s]) => s)
        .map(function([op, s]) {
            var modelName = s.model_id.split('/').pop();
            return '<tr>' +
                '<td style="color:#aaa;padding:2px 8px 2px 0;white-space:nowrap">' + op + '</td>' +
                '<td style="color:#ddd">' + modelName + '</td>' +
                '<td style="color:#888;padding-left:8px;font-size:10px">' + s.memory_opt + '</td>' +
            '</tr>';
        })
        .join('');

    var warnHtml = (g.warnings || []).length
        ? '<div style="color:#ffaa44;margin-top:6px;font-size:10px">' +
          g.warnings.map(function(w) { return '⚠ ' + w; }).join('<br>') + '</div>'
        : '';

    return '<div style="background:#1a2a1a;border:1px solid #2a4a2a;border-radius:6px;padding:10px;font-size:11px;font-family:monospace">' +
        '<div style="color:#44cc44;font-size:12px;margin-bottom:6px">⬛ ' + (g.device_name || 'GPU') + '</div>' +
        '<div style="color:#aaa">VRAM: <span style="color:#ddd">' + g.vram_total_gb + ' GB total · ' + g.vram_free_gb + ' GB free</span></div>' +
        '<div style="color:#aaa">Compute: <span style="color:#ddd">CC ' + g.compute_capability + '</span>' +
            (flags ? '  <span style="color:#888">' + flags + '</span>' : '') + '</div>' +
        '<div style="color:#aaa">Effective: <span style="color:#ddd">' + g.effective_vram_gb + ' GB</span>' +
            '  Tier: <span style="color:#44cc44">' + g.tier + '</span></div>' +
        (rows ? '<div style="color:#aaa;margin-top:8px">Models selected:</div>' +
                '<table style="width:100%;margin-top:3px">' + rows + '</table>' : '') +
        warnHtml +
    '</div>';
}

export default Tools_ai_provider_settings_class;
