/**
 * Selection Effects - Apply effects only to the selected area
 * Works with any selection tool (Smart Select, Brush Select, Magic Wand, Lasso, Ellipse)
 * Useful for CNC depth maps where you want to modify specific objects
 */

import app from './../../app.js';
import config from './../../config.js';
import Dialog_class from './../../libs/popup.js';
import Base_layers_class from './../../core/base-layers.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

class Image_selection_effects_class {

    constructor() {
        if (instance) {
            return instance;
        }
        instance = this;

        this.POP = new Dialog_class();
        this.Base_layers = new Base_layers_class();
    }

    /**
     * Check if there's a valid selection
     */
    hasSelection() {
        return window.smartSelectMask && window.smartSelectMask.canvas;
    }

    /**
     * Invert colors only in the selected area
     */
    invert_selection() {
        var _this = this;

        if (!this.hasSelection()) {
            alertify.error('No selection. Use a selection tool first (Smart Select, Brush Select, Magic Wand, etc.)');
            return;
        }

        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer');
            return;
        }

        var settings = {
            title: 'Invert Selection',
            preview: true,
            params: [
                {
                    name: "strength",
                    title: "Strength:",
                    value: 100,
                    range: [0, 100]
                },
                {
                    name: "preserve_luminosity",
                    title: "Preserve Luminosity:",
                    value: false
                }
            ],
            on_change: function (params, canvas_preview, w, h) {
                var img = canvas_preview.getImageData(0, 0, w, h);
                var data = _this.apply_invert(img, params);
                canvas_preview.putImageData(data, 0, 0);
            },
            on_finish: function (params) {
                _this.save_invert(params);
            },
        };
        this.POP.show(settings);
    }

    apply_invert(imageData, params) {
        if (!this.hasSelection()) return imageData;

        var data = imageData.data;
        var width = imageData.width;
        var height = imageData.height;
        var strength = (params.strength || 100) / 100;
        var preserveLuminosity = params.preserve_luminosity || false;

        // Get mask data
        var maskCanvas = window.smartSelectMask.canvas;
        var maskCtx = maskCanvas.getContext('2d');

        // Scale mask to match current canvas size if needed
        var scaledMask = document.createElement('canvas');
        scaledMask.width = width;
        scaledMask.height = height;
        var scaledCtx = scaledMask.getContext('2d');
        scaledCtx.drawImage(maskCanvas, 0, 0, width, height);

        var maskData = scaledCtx.getImageData(0, 0, width, height).data;

        for (var i = 0; i < data.length; i += 4) {
            var maskValue = maskData[i] / 255; // 0-1 range

            if (maskValue > 0.5) { // Inside selection
                var r = data[i];
                var g = data[i + 1];
                var b = data[i + 2];

                // Invert colors
                var newR = 255 - r;
                var newG = 255 - g;
                var newB = 255 - b;

                if (preserveLuminosity) {
                    // Calculate original and new luminosity
                    var oldLum = 0.299 * r + 0.587 * g + 0.114 * b;
                    var newLum = 0.299 * newR + 0.587 * newG + 0.114 * newB;

                    // Adjust to preserve luminosity
                    if (newLum > 0) {
                        var ratio = oldLum / newLum;
                        newR = Math.min(255, newR * ratio);
                        newG = Math.min(255, newG * ratio);
                        newB = Math.min(255, newB * ratio);
                    }
                }

                // Apply strength (blend between original and inverted)
                data[i] = Math.round(r + (newR - r) * strength);
                data[i + 1] = Math.round(g + (newG - g) * strength);
                data[i + 2] = Math.round(b + (newB - b) * strength);
            }
        }

        return imageData;
    }

    save_invert(params) {
        var canvas = this.Base_layers.convert_layer_to_canvas(null, true);
        var ctx = canvas.getContext("2d");

        var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        var data = this.apply_invert(img, params);
        ctx.putImageData(data, 0, 0);

        return app.State.do_action(
            new app.Actions.Update_layer_image_action(canvas)
        );
    }

    /**
     * Adjust brightness/contrast only in the selected area
     */
    adjust_selection() {
        var _this = this;

        if (!this.hasSelection()) {
            alertify.error('No selection. Use a selection tool first.');
            return;
        }

        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer');
            return;
        }

        var settings = {
            title: 'Adjust Selection',
            preview: true,
            params: [
                {name: "brightness", title: "Brightness:", value: 0, range: [-100, 100]},
                {name: "contrast", title: "Contrast:", value: 0, range: [-100, 100]},
                {name: "gamma", title: "Gamma:", value: 1, range: [0.1, 3], step: 0.1},
            ],
            on_change: function (params, canvas_preview, w, h) {
                var img = canvas_preview.getImageData(0, 0, w, h);
                var data = _this.apply_adjust(img, params);
                canvas_preview.putImageData(data, 0, 0);
            },
            on_finish: function (params) {
                _this.save_adjust(params);
            },
        };
        this.POP.show(settings);
    }

    apply_adjust(imageData, params) {
        if (!this.hasSelection()) return imageData;

        var data = imageData.data;
        var width = imageData.width;
        var height = imageData.height;
        var brightness = (params.brightness || 0) * 2.55;
        var contrast = (params.contrast || 0) / 100;
        var gamma = params.gamma || 1;

        var factor = (1 + contrast);

        // Get mask data
        var maskCanvas = window.smartSelectMask.canvas;
        var scaledMask = document.createElement('canvas');
        scaledMask.width = width;
        scaledMask.height = height;
        var scaledCtx = scaledMask.getContext('2d');
        scaledCtx.drawImage(maskCanvas, 0, 0, width, height);
        var maskData = scaledCtx.getImageData(0, 0, width, height).data;

        for (var i = 0; i < data.length; i += 4) {
            var maskValue = maskData[i] / 255;

            if (maskValue > 0.5) {
                for (var c = 0; c < 3; c++) {
                    var value = data[i + c];

                    // Apply brightness
                    value += brightness;

                    // Apply contrast
                    value = ((value - 128) * factor) + 128;

                    // Apply gamma
                    value = 255 * Math.pow(value / 255, 1 / gamma);

                    data[i + c] = Math.max(0, Math.min(255, Math.round(value)));
                }
            }
        }

        return imageData;
    }

    save_adjust(params) {
        var canvas = this.Base_layers.convert_layer_to_canvas(null, true);
        var ctx = canvas.getContext("2d");

        var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        var data = this.apply_adjust(img, params);
        ctx.putImageData(data, 0, 0);

        return app.State.do_action(
            new app.Actions.Update_layer_image_action(canvas)
        );
    }

    /**
     * Convert selection to greyscale (useful for depth maps)
     */
    greyscale_selection() {
        var _this = this;

        if (!this.hasSelection()) {
            alertify.error('No selection. Use a selection tool first.');
            return;
        }

        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer');
            return;
        }

        var settings = {
            title: 'Greyscale Selection',
            preview: true,
            params: [
                {
                    name: "method",
                    title: "Method:",
                    values: ["Luminosity", "Average", "Lightness"],
                    value: "Luminosity"
                },
                {name: "invert", title: "Invert:", value: false},
            ],
            on_change: function (params, canvas_preview, w, h) {
                var img = canvas_preview.getImageData(0, 0, w, h);
                var data = _this.apply_greyscale_selection(img, params);
                canvas_preview.putImageData(data, 0, 0);
            },
            on_finish: function (params) {
                _this.save_greyscale_selection(params);
            },
        };
        this.POP.show(settings);
    }

    apply_greyscale_selection(imageData, params) {
        if (!this.hasSelection()) return imageData;

        var data = imageData.data;
        var width = imageData.width;
        var height = imageData.height;
        var method = params.method || "Luminosity";
        var invert = params.invert || false;

        var maskCanvas = window.smartSelectMask.canvas;
        var scaledMask = document.createElement('canvas');
        scaledMask.width = width;
        scaledMask.height = height;
        var scaledCtx = scaledMask.getContext('2d');
        scaledCtx.drawImage(maskCanvas, 0, 0, width, height);
        var maskData = scaledCtx.getImageData(0, 0, width, height).data;

        for (var i = 0; i < data.length; i += 4) {
            var maskValue = maskData[i] / 255;

            if (maskValue > 0.5) {
                var r = data[i];
                var g = data[i + 1];
                var b = data[i + 2];
                var grey;

                switch (method) {
                    case "Luminosity":
                        grey = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                        break;
                    case "Average":
                        grey = (r + g + b) / 3;
                        break;
                    case "Lightness":
                        grey = (Math.max(r, g, b) + Math.min(r, g, b)) / 2;
                        break;
                    default:
                        grey = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                }

                if (invert) {
                    grey = 255 - grey;
                }

                grey = Math.max(0, Math.min(255, Math.round(grey)));

                data[i] = grey;
                data[i + 1] = grey;
                data[i + 2] = grey;
            }
        }

        return imageData;
    }

    save_greyscale_selection(params) {
        var canvas = this.Base_layers.convert_layer_to_canvas(null, true);
        var ctx = canvas.getContext("2d");

        var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        var data = this.apply_greyscale_selection(img, params);
        ctx.putImageData(data, 0, 0);

        return app.State.do_action(
            new app.Actions.Update_layer_image_action(canvas)
        );
    }
}

export default Image_selection_effects_class;
