/**
 * ProviderBadge — compact status indicator in the left toolbar footer.
 * Shows a dot + 3-5 char label; all details in the tooltip.
 */

import { getCapabilities } from '../../api/capabilities.js';

export async function mountProviderBadge(container) {
    var caps = await getCapabilities();

    var badge = document.createElement('div');
    badge.id = 'provider-badge';
    badge.style.cssText = [
        'display:flex', 'flex-direction:column', 'align-items:center', 'gap:2px',
        'padding:4px 2px 4px',
        'font-size:9px', 'font-family:sans-serif', 'line-height:1.2',
        'cursor:default', 'user-select:none',
        'width:100%', 'box-sizing:border-box',
        'text-align:center', 'word-break:break-word',
    ].join(';');

    var dot = document.createElement('span');
    dot.style.cssText = 'width:8px;height:8px;border-radius:50%;display:block;flex-shrink:0;';

    var label = document.createElement('span');
    label.style.cssText = 'color:inherit;max-width:36px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block;';

    var remote = caps.remote || {};
    var local  = caps.local  || {};

    if (remote.provider === 'local_gpu') {
        var gpuName = _shortGpuName(local.gpu_device);
        var tier = local.gpu_tier || '';

        if (remote.healthy) {
            dot.style.background = '#44cc44';
            badge.style.color = '#aaffaa';
            label.textContent = _shortTier(tier);

            var flagList = [
                local.gpu_fp16 && 'fp16',
                local.gpu_bf16 && 'bf16',
                local.gpu_fp8  && 'fp8',
                local.gpu_tensor_cores && 'TC',
            ].filter(Boolean).join(' ');

            badge.title = [
                gpuName,
                'VRAM: ' + local.gpu_vram_total + ' GB total / ' + local.gpu_vram_free + ' GB free',
                'CC: ' + local.gpu_cc + '  Eff VRAM: ' + local.gpu_eff_vram + ' GB',
                flagList ? 'Flags: ' + flagList : '',
                tier ? 'Tier: ' + tier : '',
                (local.local_gpu_warnings || []).length
                    ? 'Warnings:\n' + local.local_gpu_warnings.join('\n')
                    : '',
            ].filter(Boolean).join('\n');
        } else {
            dot.style.background = '#ffaa00';
            badge.style.color = '#ffdd88';
            label.textContent = 'GPU?';
            badge.title = 'local_gpu configured but diffusers may not be installed.\nCheck container logs.';
        }
    } else if (remote.provider && remote.healthy) {
        dot.style.background = '#44cc44';
        badge.style.color = '#aaffaa';
        label.textContent = _shortProvider(remote.provider);

        var opLines = Object.entries(remote.operations || {})
            .map(([op, s]) => op + ': ' + (s.provider || remote.provider) + ' ' + (s.healthy ? '✓' : '✗'))
            .join('\n');
        badge.title = ('Provider: ' + remote.provider) + (opLines ? '\n' + opLines : '');
    } else if (remote.provider && !remote.healthy) {
        dot.style.background = '#ffaa00';
        badge.style.color = '#ffdd88';
        label.textContent = _shortProvider(remote.provider) + '?';
        badge.title = remote.provider + ' configured but not reachable.\nCheck your .env URL.';
    } else {
        dot.style.background = '#888888';
        badge.style.color = '#aaaaaa';
        label.textContent = local.lama ? 'LaMa' : 'Local';
        badge.title = 'Local only (no generative AI).\nSet AI_PROVIDER in .env to enable.';
    }

    badge.appendChild(dot);
    badge.appendChild(label);

    if (container) {
        container.appendChild(badge);
    }

    return badge;
}

function _shortGpuName(name) {
    return (name || 'GPU')
        .replace(/^NVIDIA GeForce\s+/i, '')
        .replace(/^NVIDIA Quadro\s+/i, '')
        .replace(/^NVIDIA\s+/i, '')
        .replace(/^AMD Radeon\s+/i, '');
}

function _shortTier(tier) {
    if (!tier) return 'GPU';
    // sdxl_offload → SDXL, flux → FLUX, sd15 → SD15
    return tier
        .replace(/_offload$/, '')
        .replace(/_cpu$/, '')
        .toUpperCase()
        .slice(0, 6);
}

function _shortProvider(p) {
    var map = {
        openai: 'OAI', replicate: 'Rep', stability: 'Stab',
        invokeai: 'Inv', comfyui: 'CUI', local_gpu: 'GPU',
    };
    return map[p] || (p || 'AI').slice(0, 4);
}
