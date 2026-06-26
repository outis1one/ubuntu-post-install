/**
 * Greyscale Effect - Convert layer to greyscale (desaturate)
 * Useful for CNC carving, depth maps, etc.
 */

import app from './../../app.js';
import config from './../../config.js';
import Dialog_class from './../../libs/popup.js';
import Base_layers_class from './../../core/base-layers.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

class Effects_greyscale_class {

    constructor() {
        if (instance) {
            return instance;
        }
        instance = this;

        this.POP = new Dialog_class();
        this.Base_layers = new Base_layers_class();
    }

    greyscale() {
        var _this = this;

        if (config.layer.type != 'image') {
            alertify.error('This layer must contain an image. Please convert it to raster first.');
            return;
        }

        var settings = {
            title: 'Convert to Greyscale',
            preview: true,
            effects: true,
            params: [
                {
                    name: "method",
                    title: "Method:",
                    values: ["Luminosity (Rec. 709)", "Average", "Lightness", "Red Channel", "Green Channel", "Blue Channel"],
                    value: "Luminosity (Rec. 709)"
                },
                {name: "contrast", title: "Contrast:", value: 0, range: [-100, 100]},
                {name: "brightness", title: "Brightness:", value: 0, range: [-100, 100]},
                {name: "invert", title: "Invert:", value: false},
            ],
            on_change: function (params, canvas_preview, w, h) {
                var img = canvas_preview.getImageData(0, 0, w, h);
                var data = _this.apply_greyscale(img, params);
                canvas_preview.putImageData(data, 0, 0);
            },
            on_finish: function (params) {
                _this.save(params);
            },
        };
        this.POP.show(settings);
    }

    save(params) {
        var canvas = this.Base_layers.convert_layer_to_canvas(null, true);
        var ctx = canvas.getContext("2d");

        var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        var data = this.apply_greyscale(img, params);
        ctx.putImageData(data, 0, 0);

        return app.State.do_action(
            new app.Actions.Update_layer_image_action(canvas)
        );
    }

    apply_greyscale(imageData, params) {
        var data = imageData.data;
        var method = params.method;
        var contrast = (params.contrast || 0) / 100;
        var brightness = (params.brightness || 0) * 2.55; // Convert to 0-255 range
        var invert = params.invert || false;

        // Contrast factor
        var factor = (1 + contrast);

        for (var i = 0; i < data.length; i += 4) {
            if (data[i + 3] === 0) continue; // Skip transparent pixels

            var r = data[i];
            var g = data[i + 1];
            var b = data[i + 2];
            var grey;

            // Calculate greyscale value based on method
            switch (method) {
                case "Luminosity (Rec. 709)":
                    // Standard HDTV (Rec. 709) - most accurate perceptual
                    grey = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    break;
                case "Average":
                    grey = (r + g + b) / 3;
                    break;
                case "Lightness":
                    // HSL lightness
                    grey = (Math.max(r, g, b) + Math.min(r, g, b)) / 2;
                    break;
                case "Red Channel":
                    grey = r;
                    break;
                case "Green Channel":
                    grey = g;
                    break;
                case "Blue Channel":
                    grey = b;
                    break;
                default:
                    grey = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            }

            // Apply brightness
            grey += brightness;

            // Apply contrast (around middle grey)
            grey = ((grey - 128) * factor) + 128;

            // Invert if requested
            if (invert) {
                grey = 255 - grey;
            }

            // Clamp to valid range
            grey = Math.max(0, Math.min(255, Math.round(grey)));

            data[i] = grey;
            data[i + 1] = grey;
            data[i + 2] = grey;
        }

        return imageData;
    }

    demo(canvas_id, canvas_thumb) {
        var canvas = document.getElementById(canvas_id);
        var ctx = canvas.getContext("2d");
        ctx.drawImage(canvas_thumb, 0, 0);

        var img = ctx.getImageData(0, 0, canvas_thumb.width, canvas_thumb.height);
        var params = {
            method: "Luminosity (Rec. 709)",
            contrast: 0,
            brightness: 0,
            invert: false
        };
        var data = this.apply_greyscale(img, params);
        ctx.putImageData(data, 0, 0);
    }
}

export default Effects_greyscale_class;
