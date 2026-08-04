/**
 * Backend capabilities singleton.
 * Fetched once on load from GET /api/config.
 * Tools use this to decide whether to show, grey out, or show tooltips.
 *
 * Shape:
 * {
 *   local:  { lama, rembg, opencv, gpu_detected },
 *   remote: { provider, capabilities: string[], healthy }
 * }
 */

import apiService from '../services/api.js';

const DEFAULT_CAPS = {
    local:  { lama: false, rembg: false, opencv: true, gpu_detected: false },
    remote: { provider: null, capabilities: [], healthy: false },
};

let _caps = null;
let _fetchPromise = null;
let _gpuStatus = null;
let _gpuFetchPromise = null;

/**
 * Return capabilities (fetched lazily, cached thereafter).
 * Always resolves — falls back to DEFAULT_CAPS on network error.
 */
export async function getCapabilities() {
    if (_caps) return _caps;
    if (!_fetchPromise) {
        _fetchPromise = apiService.getConfig()
            .then(data => { _caps = data || DEFAULT_CAPS; return _caps; })
            .catch(() => { _caps = DEFAULT_CAPS; return _caps; });
    }
    return _fetchPromise;
}

/**
 * Synchronous check — returns cached value or DEFAULT_CAPS if not yet loaded.
 */
export function getCachedCapabilities() {
    return _caps || DEFAULT_CAPS;
}

/**
 * True if the remote provider is configured and healthy.
 */
export function hasRemote() {
    return !!(_caps?.remote?.healthy);
}

/**
 * Fetch and cache detailed GPU status (hardware, feature flags, model selection per op).
 * Calls /api/gpu/status — only meaningful when AI_PROVIDER=local_gpu.
 * Returns null on error.
 */
export async function getGpuStatus() {
    if (_gpuStatus !== null) return _gpuStatus;
    if (!_gpuFetchPromise) {
        _gpuFetchPromise = apiService.getGpuStatus()
            .then(data => { _gpuStatus = data; return _gpuStatus; })
            .catch(() => { _gpuStatus = null; return null; });
    }
    return _gpuFetchPromise;
}

/**
 * Invalidate cache and re-fetch (call after saving provider settings).
 */
export async function refreshCapabilities() {
    _caps = null;
    _fetchPromise = null;
    _gpuStatus = null;
    _gpuFetchPromise = null;
    return getCapabilities();
}

/**
 * Kick off the fetch immediately at module load time so it's ready when tools need it.
 */
getCapabilities();

export default { getCapabilities, getCachedCapabilities, hasRemote, refreshCapabilities, getGpuStatus };
