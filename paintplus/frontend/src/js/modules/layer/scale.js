/**
 * Layer Scale module - Scale individual layers (like GIMP's Scale Layer)
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import Helper_class from './../../libs/helpers.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import Pica from './../../../../node_modules/pica/dist/pica.js';

var instance = null;

class Layer_scale_class {

    constructor() {
        if (instance) {
            return instance;
        }
        instance = this;

        this.Base_layers = new Base_layers_class();
        this.POP = new Dialog_class();
        this.Helper = new Helper_class();
        this.pica = Pica();
    }

    scale() {
        var _this = this;

        if (config.layer.type != 'image') {
            alertify.error('Please convert layer to raster first (Layer > Raster)');
            return;
        }

        var currentWidth = config.layer.width;
        var currentHeight = config.layer.height;
        var aspectRatio = currentWidth / currentHeight;

        var settings = {
            title: 'Scale Layer',
            params: [
                {name: "width", title: "Width:", value: currentWidth, placeholder: currentWidth},
                {name: "height", title: "Height:", value: currentHeight, placeholder: currentHeight},
                {name: "width_percent", title: "Width %:", value: 100, placeholder: 100},
                {name: "height_percent", title: "Height %:", value: 100, placeholder: 100},
                {name: "maintain_aspect", title: "Maintain Aspect Ratio:", value: true},
                {name: "interpolation", title: "Interpolation:", values: ["Lanczos (Best)", "Bilinear", "Nearest"]},
            ],
            on_change: function(params) {
                // Auto-adjust to maintain aspect ratio if enabled
                if (params.maintain_aspect) {
                    var widthInput = document.getElementById("pop_data_width");
                    var heightInput = document.getElementById("pop_data_height");
                    var widthPercentInput = document.getElementById("pop_data_width_percent");
                    var heightPercentInput = document.getElementById("pop_data_height_percent");

                    // This is simplified - in practice you'd track which field changed
                }
            },
            on_finish: function (params) {
                _this.do_scale(params);
            },
        };
        this.POP.show(settings);
    }

    async do_scale(params) {
        var layer = config.layer;

        if (layer.type != 'image') {
            alertify.error('Layer must be an image');
            return;
        }

        var currentWidth = layer.width;
        var currentHeight = layer.height;

        // Calculate new dimensions
        var newWidth, newHeight;

        if (params.width && params.width != currentWidth) {
            newWidth = parseInt(params.width);
            if (params.maintain_aspect) {
                newHeight = Math.round(newWidth / (currentWidth / currentHeight));
            } else {
                newHeight = params.height ? parseInt(params.height) : currentHeight;
            }
        } else if (params.height && params.height != currentHeight) {
            newHeight = parseInt(params.height);
            if (params.maintain_aspect) {
                newWidth = Math.round(newHeight * (currentWidth / currentHeight));
            } else {
                newWidth = params.width ? parseInt(params.width) : currentWidth;
            }
        } else if (params.width_percent && params.width_percent != 100) {
            newWidth = Math.round(currentWidth * params.width_percent / 100);
            if (params.maintain_aspect) {
                newHeight = Math.round(currentHeight * params.width_percent / 100);
            } else {
                newHeight = Math.round(currentHeight * (params.height_percent || 100) / 100);
            }
        } else if (params.height_percent && params.height_percent != 100) {
            newHeight = Math.round(currentHeight * params.height_percent / 100);
            if (params.maintain_aspect) {
                newWidth = Math.round(currentWidth * params.height_percent / 100);
            } else {
                newWidth = Math.round(currentWidth * (params.width_percent || 100) / 100);
            }
        } else {
            newWidth = parseInt(params.width) || currentWidth;
            newHeight = parseInt(params.height) || currentHeight;
        }

        if (newWidth <= 0 || newHeight <= 0) {
            alertify.error('Invalid dimensions');
            return;
        }

        if (newWidth === currentWidth && newHeight === currentHeight) {
            alertify.warning('No change in size');
            return;
        }

        // Get canvas from layer
        var canvas = this.Base_layers.convert_layer_to_canvas(layer.id, true, false);
        var ctx = canvas.getContext("2d");

        // Create destination canvas
        var destCanvas = document.createElement('canvas');
        destCanvas.width = newWidth;
        destCanvas.height = newHeight;
        var destCtx = destCanvas.getContext('2d');

        // Perform resize based on interpolation method
        if (params.interpolation === "Lanczos (Best)") {
            await this.pica.resize(canvas, destCanvas, { alpha: true });
        } else if (params.interpolation === "Bilinear") {
            destCtx.imageSmoothingEnabled = true;
            destCtx.imageSmoothingQuality = 'high';
            destCtx.drawImage(canvas, 0, 0, newWidth, newHeight);
        } else {
            // Nearest neighbor
            destCtx.imageSmoothingEnabled = false;
            destCtx.drawImage(canvas, 0, 0, newWidth, newHeight);
        }

        // Calculate new position (keep center in same place)
        var centerX = layer.x + layer.width / 2;
        var centerY = layer.y + layer.height / 2;
        var newX = Math.round(centerX - newWidth / 2);
        var newY = Math.round(centerY - newHeight / 2);

        // Apply the changes
        app.State.do_action(
            new app.Actions.Bundle_action('scale_layer', 'Scale Layer', [
                new app.Actions.Update_layer_image_action(destCanvas, layer.id),
                new app.Actions.Update_layer_action(layer.id, {
                    x: newX,
                    y: newY,
                    width: newWidth,
                    height: newHeight,
                    width_original: newWidth,
                    height_original: newHeight
                })
            ])
        );

        alertify.success('Layer scaled to ' + newWidth + 'x' + newHeight);
    }
}

export default Layer_scale_class;
