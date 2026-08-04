/**
 * API Service for communicating with the FastAPI backend
 * Handles SAM selection and AI inpainting requests
 */

class ApiService {
    constructor() {
        // Backend API base URL
        // In unified container: empty string (same origin)
        // With separate nginx frontend: '/api' (proxied to backend)
        this.baseUrl = window.API_BASE_URL || '';
    }

    /**
     * Call SAM (Segment Anything Model) for smart selection
     * @param {string} imageData - Base64 encoded image data
     * @param {number} pointX - X coordinate of click point
     * @param {number} pointY - Y coordinate of click point
     * @returns {Promise<{mask: ImageData, polygon: Array}>}
     */
    async smartSelect(imageData, pointX, pointY) {
        const response = await fetch(`${this.baseUrl}/tools/smart-select-base64`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                image: imageData,
                point_x: pointX,
                point_y: pointY,
            }),
        });

        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `SAM request failed: ${response.status}`);
        }

        return response.json();
    }

    /**
     * Call AI inpainting to edit a selected region
     * @param {string} imageData - Base64 encoded image data
     * @param {string} maskData - Base64 encoded mask data (white = area to edit)
     * @param {string} prompt - Text prompt describing desired edit
     * @param {Object} options - Additional options
     * @returns {Promise<{result: string}>} - Base64 encoded result image
     */
    async inpaint(imageData, maskData, prompt, options = {}) {
        const response = await fetch(`${this.baseUrl}/tools/inpaint`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                image: imageData,
                mask: maskData,
                prompt: prompt,
                negative_prompt: options.negativePrompt || '',
                strength: options.strength || 0.8,
                guidance_scale: options.guidanceScale || 7.5,
            }),
        });

        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `Inpaint request failed: ${response.status}`);
        }

        return response.json();
    }

    /**
     * Remove background from image using AI (BEN2 / BiRefNet-HR / U2Net / rembg)
     * @param {string} imageData - Base64 encoded image data
     * @param {string} [model='auto'] - "auto", "ben2", "birefnet-hr", "u2net", or "rembg"
     * @returns {Promise<{result: string, width: number, height: number, method: string}>} - Base64 encoded result with transparency
     */
    async removeBackground(imageData, model = 'auto') {
        const response = await fetch(`${this.baseUrl}/tools/remove-background-base64`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                image: imageData,
                model: model,
            }),
        });

        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `Remove background request failed: ${response.status}`);
        }

        return response.json();
    }

    /**
     * AI erase using LaMa (local, no API key needed)
     * @param {string} imageData - Base64 encoded image
     * @param {string} maskData - Base64 encoded mask (white = erase)
     * @returns {Promise<{result: string, method: string}>}
     */
    async erase(imageData, maskData) {
        const response = await fetch(`${this.baseUrl}/api/erase`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ image: imageData, mask: maskData }),
        });
        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `Erase request failed: ${response.status}`);
        }
        return response.json();
    }

    /**
     * Text-to-image via remote provider
     * @param {string} prompt
     * @param {Object} options - width, height, negativePrompt, steps, cfgScale, model
     * @returns {Promise<{result: string}>}
     */
    async textToImage(prompt, options = {}) {
        const response = await fetch(`${this.baseUrl}/api/generate/txt2img`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                prompt,
                width: options.width || 1024,
                height: options.height || 1024,
                negative_prompt: options.negativePrompt || '',
                steps: options.steps || 30,
                cfg_scale: options.cfgScale || 7.5,
                model: options.model || null,
                seed: options.seed || 0,
            }),
        });
        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `Text-to-image failed: ${response.status}`);
        }
        return response.json();
    }

    /**
     * Image-to-image via remote provider
     * @param {string} imageData - Base64 encoded image
     * @param {string} prompt
     * @param {Object} options
     * @returns {Promise<{result: string}>}
     */
    async imageToImage(imageData, prompt, options = {}) {
        const response = await fetch(`${this.baseUrl}/api/generate/img2img`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                image: imageData,
                prompt,
                strength: options.strength || 0.75,
                negative_prompt: options.negativePrompt || '',
                steps: options.steps || 30,
                cfg_scale: options.cfgScale || 7.5,
                model: options.model || null,
            }),
        });
        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `Image-to-image failed: ${response.status}`);
        }
        return response.json();
    }

    /**
     * Inpaint with prompt via remote provider
     * @param {string} imageData - Base64
     * @param {string} maskData - Base64
     * @param {string} prompt
     * @param {Object} options
     * @returns {Promise<{result: string}>}
     */
    async remoteInpaint(imageData, maskData, prompt, options = {}) {
        const response = await fetch(`${this.baseUrl}/api/inpaint/remote`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                image: imageData,
                mask: maskData,
                prompt,
                negative_prompt: options.negativePrompt || '',
                steps: options.steps || 30,
                cfg_scale: options.cfgScale || 7.5,
                model: options.model || null,
            }),
        });
        if (!response.ok) {
            const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
            throw new Error(error.detail || `Remote inpaint failed: ${response.status}`);
        }
        return response.json();
    }

    /**
     * Fetch backend capabilities (local tools available, remote provider status).
     * @returns {Promise<Object>}
     */
    async getConfig() {
        try {
            const response = await fetch(`${this.baseUrl}/api/config`);
            if (!response.ok) return null;
            return response.json();
        } catch {
            return null;
        }
    }

    /**
     * Fetch GPU status: hardware, feature flags, and selected models per operation.
     * Only meaningful when AI_PROVIDER=local_gpu.
     * @returns {Promise<Object|null>}
     */
    async getGpuStatus() {
        try {
            const response = await fetch(`${this.baseUrl}/api/gpu/status`);
            if (!response.ok) return null;
            return response.json();
        } catch {
            return null;
        }
    }

    /**
     * Health check for the backend
     * @returns {Promise<boolean>}
     */
    async healthCheck() {
        try {
            const response = await fetch(`${this.baseUrl}/health`);
            return response.ok;
        } catch {
            return false;
        }
    }
}

// Singleton instance
const apiService = new ApiService();
export default apiService;
