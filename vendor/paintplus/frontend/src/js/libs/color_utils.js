/**
 * Color conversion and Pantone matching utilities.
 *
 * hexToRgb(hex)          → { r, g, b }
 * rgbToHsl(r,g,b)        → { h, s, l }  (h=0-360, s/l=0-100)
 * rgbToLab(r,g,b)        → { L, a, b }  (CIE LAB D65)
 * deltaE(lab1, lab2)     → number       (CIE76, lower = more similar)
 * nearestPantone(hex)    → { name, hex, deltaE }
 */

import PANTONE_COLORS from './../data/pantone_colors.js';

// Pre-convert Pantone database to LAB once at module load
const _pantonelab = PANTONE_COLORS.map(([name, hex]) => {
    const { r, g, b } = hexToRgb(hex);
    return { name, hex, lab: rgbToLab(r, g, b) };
});

export function hexToRgb(hex) {
    const h = hex.replace('#', '');
    const n = parseInt(h.length === 3
        ? h.split('').map(c => c + c).join('')
        : h, 16);
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

export function rgbToHex(r, g, b) {
    return '#' + [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('');
}

export function rgbToHsl(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    let h, s, l = (max + min) / 2;
    if (max === min) {
        h = s = 0;
    } else {
        const d = max - min;
        s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        switch (max) {
            case r: h = ((g - b) / d + (g < b ? 6 : 0)) / 6; break;
            case g: h = ((b - r) / d + 2) / 6; break;
            case b: h = ((r - g) / d + 4) / 6; break;
        }
    }
    return { h: Math.round(h * 360), s: Math.round(s * 100), l: Math.round(l * 100) };
}

export function rgbToLab(r, g, b) {
    // sRGB → linear
    let R = r / 255, G = g / 255, B = b / 255;
    R = R > 0.04045 ? Math.pow((R + 0.055) / 1.055, 2.4) : R / 12.92;
    G = G > 0.04045 ? Math.pow((G + 0.055) / 1.055, 2.4) : G / 12.92;
    B = B > 0.04045 ? Math.pow((B + 0.055) / 1.055, 2.4) : B / 12.92;

    // linear RGB → XYZ (D65)
    let X = R * 0.4124564 + G * 0.3575761 + B * 0.1804375;
    let Y = R * 0.2126729 + G * 0.7151522 + B * 0.0721750;
    let Z = R * 0.0193339 + G * 0.1191920 + B * 0.9503041;

    // XYZ → LAB (D65 white = 0.95047, 1.0, 1.08883)
    const f = v => v > 0.008856 ? Math.cbrt(v) : 7.787 * v + 16 / 116;
    X = f(X / 0.95047); Y = f(Y / 1.0); Z = f(Z / 1.08883);

    return { L: 116 * Y - 16, a: 500 * (X - Y), b: 200 * (Y - Z) };
}

export function deltaE(lab1, lab2) {
    const dL = lab1.L - lab2.L;
    const da = lab1.a - lab2.a;
    const db = lab1.b - lab2.b;
    return Math.sqrt(dL * dL + da * da + db * db);
}

/**
 * Find the closest Pantone color to a hex value.
 * Returns { name, hex, deltaE, quality }
 * quality: 'excellent' (<2), 'good' (2-5), 'fair' (5-10), 'poor' (>10)
 */
export function nearestPantone(hex) {
    const { r, g, b } = hexToRgb(hex);
    const lab = rgbToLab(r, g, b);

    let best = null, bestDE = Infinity;
    for (const entry of _pantonelab) {
        const de = deltaE(lab, entry.lab);
        if (de < bestDE) { bestDE = de; best = entry; }
    }

    const de = Math.round(bestDE * 10) / 10;
    const quality = de < 2 ? 'excellent' : de < 5 ? 'good' : de < 10 ? 'fair' : 'poor';
    return { name: best.name, hex: best.hex, deltaE: de, quality };
}

/**
 * Quality label + color for ΔE badge.
 */
export function deltaEBadge(quality) {
    const map = {
        excellent: { label: 'Excellent match', color: '#4ade80' },
        good:      { label: 'Good match',      color: '#86efac' },
        fair:      { label: 'Fair match',       color: '#fbbf24' },
        poor:      { label: 'Poor match — color may shift in print', color: '#f87171' },
    };
    return map[quality] || map.poor;
}
