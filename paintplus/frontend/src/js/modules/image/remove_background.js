/**
 * Remove Background Module - Uses AI to remove background and create transparent layer
 */

import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import Helper_class from './../../libs/helpers.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import apiService from './../../services/api.js';

var instance = null;

class Image_remove_background_class {

    constructor() {
        // Singleton
        if (instance) {
            return instance;
        }
        instance = this;

        this.Base_layers = new Base_layers_class();
        this.Helper = new Helper_class();
        this.Dialog = new Dialog_class();
        this.isProcessing = false;
    }

    /**
     * Remove background from current layer
     * Creates a new layer with transparent background
     */
    async remove_background() {
        var _this = this;

        if (this.isProcessing) {
            alertify.warning('Already processing... please wait');
            return;
        }

        // Check if current layer is an image
        if (config.layer.type != 'image') {
            alertify.error('Current layer must be an image');
            return;
        }

        var settings = {
            title: 'Remove Background',
            params: [
                { name: "info", title: "AI will detect the main subject and remove the background.", type: "label" },
                {
                    name: "model", title: "Model:", value: "auto", type: "select",
                    values: ["auto", "ben2", "birefnet-hr", "u2net"],
                    comment: "auto = best available (BEN2 by default). BiRefNet-HR is slower but sharper on high-res/print work.",
                },
                { name: "new_layer", title: "Create as new layer:", value: true },
                { name: "trim_result", title: "Trim transparent edges:", value: false },
            ],
            on_finish: async function (params) {
                await _this.do_remove_background(params);
            },
        };
        this.Dialog.show(settings);
    }

    async do_remove_background(params) {
        this.isProcessing = true;
        alertify.message('AI is removing background... this may take a moment');

        try {
            // Get current layer image as base64
            var canvas = document.createElement('canvas');
            var ctx = canvas.getContext('2d');
            canvas.width = config.layer.width_original;
            canvas.height = config.layer.height_original;
            ctx.drawImage(config.layer.link, 0, 0);

            var imageData = canvas.toDataURL('image/png').split(',')[1];

            // Call backend API
            var result = await apiService.removeBackground(imageData, params.model);

            // Create image from result
            var resultImage = new Image();
            resultImage.onload = () => {
                if (params.new_layer) {
                    // Create as new layer
                    var layerParams = {
                        x: config.layer.x,
                        y: config.layer.y,
                        width: resultImage.width,
                        height: resultImage.height,
                        width_original: resultImage.width,
                        height_original: resultImage.height,
                        type: 'image',
                        name: config.layer.name + ' (No BG)',
                        data: 'data:image/png;base64,' + result.result
                    };

                    app.State.do_action(
                        new app.Actions.Bundle_action('remove_background', 'Remove Background', [
                            new app.Actions.Insert_layer_action(layerParams)
                        ])
                    );

                    alertify.success('Background removed! New layer created.');
                } else {
                    // Replace current layer
                    var newCanvas = document.createElement('canvas');
                    newCanvas.width = resultImage.width;
                    newCanvas.height = resultImage.height;
                    var newCtx = newCanvas.getContext('2d');
                    newCtx.drawImage(resultImage, 0, 0);

                    app.State.do_action(
                        new app.Actions.Bundle_action('remove_background', 'Remove Background', [
                            new app.Actions.Update_layer_image_action(newCanvas, config.layer.id)
                        ])
                    );

                    alertify.success('Background removed!');
                }

                // Enable transparency if not already
                if (config.TRANSPARENCY == false) {
                    config.TRANSPARENCY = true;
                    this.Base_layers.render();
                    alertify.message('Transparency enabled to show removed background');
                }

                this.isProcessing = false;
            };

            resultImage.onerror = () => {
                alertify.error('Failed to load result image');
                this.isProcessing = false;
            };

            resultImage.src = 'data:image/png;base64,' + result.result;

        } catch (error) {
            console.error('Remove background error:', error);
            alertify.error('Failed to remove background: ' + error.message);
            this.isProcessing = false;
        }
    }
}

export default Image_remove_background_class;
