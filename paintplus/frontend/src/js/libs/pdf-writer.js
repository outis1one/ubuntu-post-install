/**
 * Minimal pure-JS PDF writer for image export.
 *
 * Supports:
 *  - Single-page and multipage (one page per canvas)
 *  - RGB color space: images JPEG-encoded (browser-native, small files)
 *  - CMYK color space: raw DeviceCMYK bytes (print-ready, no alpha)
 *
 * PDF-1.4 structure used.  No external dependencies.
 *
 * Usage:
 *   PdfWriter.fromCanvases(canvases, { colorMode: 'rgb'|'cmyk', quality: 0.9, dpi: 300 })
 *     .then(blob => FileSaver.saveAs(blob, 'file.pdf'));
 */

import { rgbToCmyk } from './tiff-writer.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Encode a JS string to a Uint8Array of bytes (Latin-1 safe). */
function strBytes(s) {
    var a = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i) & 0xff;
    return a;
}

/** Concatenate multiple Uint8Arrays / ArrayBuffers into one Uint8Array. */
function concat(parts) {
    var total = 0;
    for (var i = 0; i < parts.length; i++)
        total += parts[i].byteLength || parts[i].length;
    var out = new Uint8Array(total), pos = 0;
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i] instanceof ArrayBuffer ? new Uint8Array(parts[i]) : parts[i];
        out.set(p, pos);
        pos += p.length;
    }
    return out;
}

/** canvas → raw CMYK Uint8Array (W*H*4 bytes, alpha discarded). */
function canvasToCmykBytes(canvas) {
    var idata = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
    var out   = new Uint8Array(canvas.width * canvas.height * 4);
    for (var px = 0, i = 0, len = idata.length; px < len; px += 4, i += 4) {
        var cmyk = rgbToCmyk(idata[px], idata[px + 1], idata[px + 2]);
        out[i]     = cmyk[0];
        out[i + 1] = cmyk[1];
        out[i + 2] = cmyk[2];
        out[i + 3] = cmyk[3];
    }
    return out;
}

/** canvas → JPEG Uint8Array via browser encoding. Returns a Promise. */
function canvasToJpegBytes(canvas, quality) {
    return new Promise(function(resolve) {
        canvas.toBlob(function(blob) {
            blob.arrayBuffer().then(function(buf) {
                resolve(new Uint8Array(buf));
            });
        }, 'image/jpeg', quality || 0.92);
    });
}

// ---------------------------------------------------------------------------
// PDF object builder
// ---------------------------------------------------------------------------

/**
 * Build a complete PDF byte stream for an array of pages.
 *
 * @param {Array<{width, height, colorSpace, imgBytes, filter}>} pages
 * @param {number} dpi  — used for MediaBox sizing (px → pt: pt = px * 72 / dpi)
 * @returns {Uint8Array}
 */
function buildPDF(pages, dpi) {
    dpi = dpi || 300;
    var px2pt = 72 / dpi;

    // Object registry: we'll collect byte-offset of each object for xref.
    var objs   = [];   // each element is the raw bytes of "N 0 obj ... endobj\n"
    var objNums = {};  // logical name → 1-based index

    function addObj(name, content) {
        var n = objs.length + 1;
        if (name) objNums[name] = n;
        var s = n + ' 0 obj\n' + content + '\nendobj\n';
        objs.push(strBytes(s));
        return n;
    }

    function addStreamObj(name, dict, dataBytes) {
        var n = objs.length + 1;
        if (name) objNums[name] = n;
        var header = n + ' 0 obj\n' + dict + '\nstream\n';
        var footer = '\nendstream\nendobj\n';
        var combined = concat([strBytes(header), dataBytes, strBytes(footer)]);
        objs.push(combined);
        return n;
    }

    // 1. Catalog
    addObj('catalog', '<< /Type /Catalog /Pages 2 0 R >>');

    // 2. Pages (placeholder — children added later)
    var pagesIdx = objs.length + 1;
    addObj('pages', ''); // placeholder

    // 3. Per-page objects
    var pageObjNums = [];
    for (var p = 0; p < pages.length; p++) {
        var pg      = pages[p];
        var W_pt    = (pg.width  * px2pt).toFixed(3);
        var H_pt    = (pg.height * px2pt).toFixed(3);
        var imgName = 'Im' + (p + 1);
        var imgIdx  = objs.length + 2; // will be added after content stream

        // Content stream: scale and paint image
        var contentStr = 'q ' + W_pt + ' 0 0 ' + H_pt + ' 0 0 cm /' + imgName + ' Do Q';
        var contentNum = addStreamObj(null,
            '<< /Length ' + contentStr.length + ' >>',
            strBytes(contentStr));

        // Image XObject
        var samples = pg.colorSpace === 'DeviceCMYK' ? 4 : 3;
        var imgDict  = '<< /Type /XObject /Subtype /Image'
                     + ' /Width '  + pg.width
                     + ' /Height ' + pg.height
                     + ' /ColorSpace /' + pg.colorSpace
                     + ' /BitsPerComponent 8'
                     + (pg.filter ? ' /Filter /' + pg.filter : '')
                     + ' /Length ' + pg.imgBytes.length
                     + ' >>';
        var imgNum = addStreamObj(null, imgDict, pg.imgBytes);

        // Page object
        var pageNum = addObj(null,
            '<< /Type /Page /Parent ' + pagesIdx + ' 0 R'
            + ' /MediaBox [0 0 ' + W_pt + ' ' + H_pt + ']'
            + ' /Contents ' + contentNum + ' 0 R'
            + ' /Resources << /XObject << /' + imgName + ' ' + imgNum + ' 0 R >> >>'
            + ' >>');
        pageObjNums.push(pageNum);
    }

    // Fill in Pages object properly
    var kidsStr = pageObjNums.map(function(n) { return n + ' 0 R'; }).join(' ');
    var pagesContent = '<< /Type /Pages /Kids [' + kidsStr + '] /Count ' + pages.length + ' >>';
    objs[pagesIdx - 1] = strBytes(pagesIdx + ' 0 obj\n' + pagesContent + '\nendobj\n');

    // ---- Assemble file ----
    var header   = strBytes('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'); // binary hint comment
    var offsets  = [];
    var parts    = [header];
    var bytePos  = header.length;

    for (var i = 0; i < objs.length; i++) {
        offsets.push(bytePos);
        parts.push(objs[i]);
        bytePos += objs[i].length;
    }

    // xref table
    var xrefOffset = bytePos;
    var xrefLines  = 'xref\n0 ' + (objs.length + 1) + '\n';
    xrefLines += '0000000000 65535 f \n';
    for (var i = 0; i < offsets.length; i++) {
        xrefLines += String(offsets[i]).padStart(10, '0') + ' 00000 n \n';
    }
    parts.push(strBytes(xrefLines));

    // trailer
    var trailerStr = 'trailer\n<< /Size ' + (objs.length + 1)
                   + ' /Root 1 0 R >>\nstartxref\n' + xrefOffset + '\n%%EOF\n';
    parts.push(strBytes(trailerStr));

    return concat(parts);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

var PdfWriter = {

    /**
     * Export an array of canvases as a PDF.
     *
     * @param {HTMLCanvasElement|HTMLCanvasElement[]} canvases
     * @param {object} [opts]
     * @param {'rgb'|'cmyk'} [opts.colorMode='rgb']
     * @param {number}  [opts.quality=0.92]  JPEG quality for RGB mode (0–1)
     * @param {number}  [opts.dpi=300]        dots-per-inch for page sizing
     * @returns {Promise<Blob>}
     */
    fromCanvases: function(canvases, opts) {
        if (!Array.isArray(canvases)) canvases = [canvases];
        opts = opts || {};
        var colorMode = opts.colorMode === 'cmyk' ? 'cmyk' : 'rgb';
        var dpi       = +(opts.dpi || 300) | 0;
        var quality   = opts.quality != null ? opts.quality : 0.92;

        if (colorMode === 'cmyk') {
            // Synchronous path: raw CMYK bytes
            var pages = canvases.map(function(cv) {
                return {
                    width:      cv.width,
                    height:     cv.height,
                    colorSpace: 'DeviceCMYK',
                    filter:     null,
                    imgBytes:   canvasToCmykBytes(cv),
                };
            });
            var pdfBytes = buildPDF(pages, dpi);
            return Promise.resolve(new Blob([pdfBytes], { type: 'application/pdf' }));
        } else {
            // Async path: JPEG-encode each canvas
            var promises = canvases.map(function(cv) {
                return canvasToJpegBytes(cv, quality).then(function(bytes) {
                    return {
                        width:      cv.width,
                        height:     cv.height,
                        colorSpace: 'DeviceRGB',
                        filter:     'DCTDecode',
                        imgBytes:   bytes,
                    };
                });
            });
            return Promise.all(promises).then(function(pages) {
                var pdfBytes = buildPDF(pages, dpi);
                return new Blob([pdfBytes], { type: 'application/pdf' });
            });
        }
    },
};

export default PdfWriter;
