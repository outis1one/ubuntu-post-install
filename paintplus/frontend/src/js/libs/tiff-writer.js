/**
 * TIFF writer with support for:
 *  - Single-page RGBA (32-bit, interleaved, with alpha)
 *  - Single-page CMYK (8-bit per channel, no alpha — print-ready)
 *  - Multipage variants of both (one IFD per canvas layer)
 *
 * TIFF spec references: TIFF 6.0, ISO 12234-2 (CMYK)
 * PhotometricInterpretation 2 = RGB, 5 = CMYK
 */

// --- RGB → CMYK conversion -------------------------------------------

function rgbToCmyk(r, g, b) {
    var rn = r / 255, gn = g / 255, bn = b / 255;
    var k = 1 - Math.max(rn, gn, bn);
    if (k >= 1) return [0, 0, 0, 255];
    var d = 1 - k;
    return [
        Math.round((d - rn) / d * 255),
        Math.round((d - gn) / d * 255),
        Math.round((d - bn) / d * 255),
        Math.round(k * 255),
    ];
}

// --- Low-level TIFF binary builder ------------------------------------

/**
 * Build a multipage TIFF buffer from an array of canvases.
 *
 * @param {HTMLCanvasElement[]} canvases
 * @param {'rgba'|'cmyk'} colorMode
 * @param {object} [opts]
 * @param {boolean} [opts.littleEndian=false]
 * @param {number}  [opts.dpi=300]
 * @returns {ArrayBuffer}
 */
function buildTIFF(canvases, colorMode, opts) {
    opts = opts || {};
    var lsb  = !!opts.littleEndian;
    var dpi  = +(opts.dpi || 300) | 0;

    var isCMYK = colorMode === 'cmyk';

    // IFD field counts differ: RGBA has ExtraSamples tag, CMYK does not.
    var ENTRY_COUNT = isCMYK ? 14 : 15;
    var IFD_SIZE    = 2 + ENTRY_COUNT * 12 + 4;   // count + entries + nextIFD ptr
    var FIELDS_SIZE = 64;                           // BPS(8)+XRes(8)+YRes(8)+sw(20)+dt(20)
    var PAGE_OH     = IFD_SIZE + FIELDS_SIZE;

    // Compute page start offsets inside the final buffer.
    var offsets = [];
    var total   = 8; // TIFF header
    for (var i = 0; i < canvases.length; i++) {
        offsets.push(total);
        total += PAGE_OH + canvases[i].width * canvases[i].height * 4;
    }

    var buf  = new ArrayBuffer(total);
    var view = new DataView(buf);
    var u8   = new Uint8Array(buf);
    var pos  = 0;

    function s16(v) { view.setUint16(pos, v, lsb); pos += 2; }
    function s32(v) { view.setUint32(pos, v, lsb); pos += 4; }
    function entry(tag, type, count, value) {
        s16(tag); s16(type); s32(count);
        // SHORT with count==1 gets packed into the value field with padding.
        if (type === 3 && count === 1) { s16(value); s16(0); }
        else                           { s32(value); }
    }

    // Date helpers
    var d    = new Date();
    var p2   = function(n) { return n < 10 ? '0' + n : '' + n; };
    var dtStr = d.getFullYear() + ':' + p2(d.getMonth() + 1) + ':' + p2(d.getDate())
              + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
    var swStr = 'tiff-writer 1.0\0\0\0\0\0'; // 20 chars (null-padded)

    // ---- TIFF header ----
    s16(lsb ? 0x4949 : 0x4d4d);
    s16(42);
    s32(8); // offset to first IFD

    // ---- Per-page IFDs + image data ----
    for (var p = 0; p < canvases.length; p++) {
        var cv       = canvases[p];
        var W        = cv.width, H = cv.height;
        var pageBase = offsets[p];
        var fBase    = pageBase + IFD_SIZE;          // start of fields section
        var imgBase  = fBase + FIELDS_SIZE;          // start of image data
        var nextIFD  = p + 1 < canvases.length ? offsets[p + 1] : 0;

        // IFD entry count
        s16(ENTRY_COUNT);

        entry(0x00fe, 4, 1, 0);                         // NewSubfileType
        entry(0x0100, 4, 1, W);                         // ImageWidth
        entry(0x0101, 4, 1, H);                         // ImageLength
        entry(0x0102, 3, 4, fBase);                     // BitsPerSample (offset → 4 shorts)
        entry(0x0103, 3, 1, 1);                         // Compression: none
        entry(0x0106, 3, 1, isCMYK ? 5 : 2);           // PhotometricInterp: 5=CMYK, 2=RGB
        entry(0x0111, 4, 1, imgBase);                   // StripOffsets
        entry(0x0115, 3, 1, 4);                         // SamplesPerPixel: 4
        entry(0x0117, 4, 1, W * H * 4);                // StripByteCounts
        entry(0x011a, 5, 1, fBase + 8);                 // XResolution
        entry(0x011b, 5, 1, fBase + 16);                // YResolution
        entry(0x0128, 3, 1, 2);                         // ResolutionUnit: inch
        entry(0x0131, 2, 20, fBase + 24);               // Software (20 bytes)
        entry(0x0132, 2, 20, fBase + 44);               // DateTime  (20 bytes)
        if (!isCMYK) {
            entry(0x0152, 3, 1, 2);                     // ExtraSamples: assoc. alpha (RGBA only)
        }

        s32(nextIFD);

        // ---- Fields section (64 bytes) ----
        // BitsPerSample: 8,8,8,8 as four SHORTs (8 bytes)
        s16(8); s16(8); s16(8); s16(8);
        // XResolution RATIONAL (8 bytes)
        s32(dpi); s32(1);
        // YResolution RATIONAL (8 bytes)
        s32(dpi); s32(1);
        // Software string (20 bytes, null-padded)
        for (var i = 0; i < 20; i++)
            view.setUint8(pos++, swStr.charCodeAt(i) & 0xff);
        // DateTime string (20 bytes, null-padded)
        for (var i = 0; i < 20; i++)
            view.setUint8(pos++, i < dtStr.length ? dtStr.charCodeAt(i) & 0xff : 0);

        // ---- Image data ----
        var idata = cv.getContext('2d').getImageData(0, 0, W, H).data;
        if (isCMYK) {
            // Convert RGBA → CMYK and write 4 bytes per pixel (alpha discarded)
            for (var px = 0, len = idata.length; px < len; px += 4) {
                var cmyk = rgbToCmyk(idata[px], idata[px + 1], idata[px + 2]);
                u8[pos++] = cmyk[0];
                u8[pos++] = cmyk[1];
                u8[pos++] = cmyk[2];
                u8[pos++] = cmyk[3];
            }
        } else {
            // Write RGBA directly
            u8.set(idata, pos);
            pos += idata.length;
        }
    }

    return buf;
}

// --- Public API -------------------------------------------------------

var TiffWriter = {

    /** Single-page 32-bit RGBA TIFF */
    toRGBA: function(canvas, callback, opts) {
        setTimeout(function() {
            callback(buildTIFF([canvas], 'rgba', opts));
        }, 9);
    },

    /** Single-page CMYK TIFF (print-ready, no alpha) */
    toCMYK: function(canvas, callback, opts) {
        setTimeout(function() {
            callback(buildTIFF([canvas], 'cmyk', opts));
        }, 9);
    },

    /** Multipage RGBA TIFF — one IFD per canvas in the array */
    toMultipageRGBA: function(canvases, callback, opts) {
        setTimeout(function() {
            callback(buildTIFF(canvases, 'rgba', opts));
        }, 9);
    },

    /** Multipage CMYK TIFF — one IFD per canvas in the array */
    toMultipageCMYK: function(canvases, callback, opts) {
        setTimeout(function() {
            callback(buildTIFF(canvases, 'cmyk', opts));
        }, 9);
    },

    /** Convenience: returns a Blob instead of ArrayBuffer */
    toBlob: function(canvases, colorMode, callback, opts) {
        if (!Array.isArray(canvases)) canvases = [canvases];
        setTimeout(function() {
            var buf = buildTIFF(canvases, colorMode, opts);
            callback(new Blob([buf], { type: 'image/tiff' }));
        }, 9);
    },
};

export default TiffWriter;
export { rgbToCmyk };
