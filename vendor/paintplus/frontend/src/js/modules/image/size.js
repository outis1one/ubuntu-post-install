import app from './../../app.js';
import config from './../../config.js';
import Base_gui_class from './../../core/base-gui.js';
import Base_layers_class from './../../core/base-layers.js';
import Dialog_class from './../../libs/popup.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import Tools_settings_class from './../tools/settings.js';
import Helper_class from './../../libs/helpers.js';
import Pica from './../../../../node_modules/pica/dist/pica.js';

// Common print sizes at 300 DPI: [width_px, height_px, display_label]
const PRINT_SIZES = [
	[1500, 2100, '5x7" Portrait'],
	[2100, 1500, '5x7" Landscape'],
	[2400, 3000, '8x10" Portrait'],
	[3000, 2400, '8x10" Landscape'],
	[3300, 4200, '11x14" Portrait'],
	[4200, 3300, '11x14" Landscape'],
	[3600, 4800, '18x24" Portrait 200dpi'],
	[4800, 3600, '18x24" Landscape 200dpi'],
	[5400, 7200, '18x24" Portrait 300dpi'],
	[7200, 5400, '18x24" Landscape 300dpi'],
];

class Image_size_class {

	constructor() {
		this.Base_gui = new Base_gui_class();
		this.Base_layers = new Base_layers_class();
		this.POP = new Dialog_class();
		this.Tools_settings = new Tools_settings_class();
		this.Helper = new Helper_class();
		this.pica = Pica();
		this._lastUnits = 'pixels';
	}

	size() {
		var _this = this;
		var common_dimensions = this.Base_gui.common_dimensions;
		var global_units = this.Tools_settings.get_setting('default_units');
		var resolution = this.Tools_settings.get_setting('resolution');
		var enable_autoresize = this.Tools_settings.get_setting('enable_autoresize');

		var displayUnits = (global_units === 'inches') ? 'inches' : 'pixels';
		this._lastUnits = displayUnits;

		var resolutions = ['Custom'];
		for (var i in common_dimensions) {
			var value = common_dimensions[i];
			resolutions.push(value[0] + 'x' + value[1] + ' - ' + value[2]);
		}
		// Print size presets — WxH format is parsed by existing resolution logic
		for (var ps of PRINT_SIZES) {
			resolutions.push(ps[0] + 'x' + ps[1] + ' - ' + ps[2] + ' Print');
		}

		var width = this.Helper.get_user_unit(config.WIDTH, displayUnits, resolution);
		var height = this.Helper.get_user_unit(config.HEIGHT, displayUnits, resolution);

		var settings = {
			title: 'Canvas Size',
			params: [
				{name: "units", title: "Units:", value: displayUnits, values: ["pixels", "inches"]},
				{name: "w", title: "Width:", value: width, placeholder: width, comment: displayUnits},
				{name: "h", title: "Height:", value: height, placeholder: height, comment: displayUnits},
				{name: "resolution", title: "Resolution:", values: resolutions},
				{name: "layout", title: "Layout:", value: "Custom", values: ["Custom", "Landscape", "Portrait"]},
				{name: "enable_autoresize", title: "Enable autoresize:", value: enable_autoresize},
				{name: "in_proportion", title: "In proportion:", value: false},
				{name: "resize_image", title: "Resize & crop image:", value: false},
			],
			on_change: function(params) {
				_this.units_change_handler(params);
			},
			on_finish: function (params) {
				_this.size_handler(params);
			},
		};
		this.POP.show(settings);
	}

	units_change_handler(params) {
		var units = params.units;
		if (units === this._lastUnits) return;

		this._lastUnits = units;
		var resolution = this.Tools_settings.get_setting('resolution');

		// Persist so Resize and other dialogs open with the same units
		const unitShort = {pixels: 'px', inches: '"', centimeters: 'cm', millimetres: 'mm'};
		this.Tools_settings.save_setting('default_units', units);
		this.Tools_settings.save_setting('default_units_short', unitShort[units] || units);

		var newWidth = this.Helper.get_user_unit(config.WIDTH, units, resolution);
		var newHeight = this.Helper.get_user_unit(config.HEIGHT, units, resolution);

		var wInput = document.getElementById('pop_data_w');
		var hInput = document.getElementById('pop_data_h');
		if (wInput) wInput.value = newWidth;
		if (hInput) hInput.value = newHeight;

		// Update the unit label shown next to each field
		var wComment = wInput ? wInput.nextElementSibling : null;
		var hComment = hInput ? hInput.nextElementSibling : null;
		if (wComment && wComment.classList.contains('field_comment')) wComment.textContent = units;
		if (hComment && hComment.classList.contains('field_comment')) hComment.textContent = units;
	}

	async size_handler(data) {
		var width = parseFloat(data.w);
		var height = parseFloat(data.h);
		var canvasRatio = config.WIDTH / config.HEIGHT;
		var units = data.units || this.Tools_settings.get_setting('default_units');
		var resolution = this.Tools_settings.get_setting('resolution');

		if (width < 0) width = 1;
		if (height < 0) height = 1;

		this.Tools_settings.save_setting('enable_autoresize', data.enable_autoresize);

		if (isNaN(width) && isNaN(height)) {
			alertify.error('Wrong dimensions');
			return;
		}
		if (isNaN(width)) width = height * canvasRatio;
		if (isNaN(height)) height = width / canvasRatio;

		if (data.resolution != 'Custom') {
			var dim = data.resolution.split(" ");
			dim = dim[0].split("x");
			width = parseInt(dim[0]);
			height = parseInt(dim[1]);

			// Don't apply layout swap for print presets (orientation is already encoded)
			if (data.layout == 'Portrait' && !data.resolution.includes('Print')) {
				var tmp = width;
				width = height;
				height = tmp;
			}
		} else {
			width = this.Helper.get_internal_unit(width, units, resolution);
			height = this.Helper.get_internal_unit(height, units, resolution);
		}

		width = parseInt(width);
		height = parseInt(height);

		var actions = [
			new app.Actions.Prepare_canvas_action('undo'),
			new app.Actions.Update_config_action({
				WIDTH: width,
				HEIGHT: height
			}),
		];

		// Proportional layer repositioning (only when not doing full resize+crop)
		if (data.in_proportion == true && data.resize_image != true) {
			var width_ratio = config.WIDTH / width;
			var height_ratio = config.HEIGHT / height;
			var maxRatio = Math.max(width_ratio, height_ratio);

			for (var i in config.layers) {
				var layer = config.layers[i];
				if (layer.x != null && layer.y != null) {
					actions.push(new app.Actions.Update_layer_action(layer.id, {
						x: Math.round(layer.x / width_ratio),
						y: Math.round(layer.y / height_ratio),
					}));
				}
				if (layer.width != null && layer.height != null) {
					actions.push(new app.Actions.Update_layer_action(layer.id, {
						width: Math.round(layer.width / maxRatio),
						height: Math.round(layer.height / maxRatio),
					}));
				}
			}
		}

		// Resize & center-crop image layers to fill the new canvas
		if (data.resize_image == true) {
			try {
				var cropActions = await this.get_resize_crop_actions(width, height);
				actions = actions.concat(cropActions);
			} catch (error) {
				alertify.error('Could not resize image: ' + error.message);
			}
		}

		actions.push(new app.Actions.Prepare_canvas_action('do'));

		app.State.do_action(
			new app.Actions.Bundle_action('set_image_size', 'Set Image Size', actions)
		);
	}

	/**
	 * Generates actions to scale-and-center-crop all image layers to fill targetWidth × targetHeight.
	 * Uses "cover" scaling: the image is scaled so it fills the target, then cropped from the center.
	 */
	async get_resize_crop_actions(targetWidth, targetHeight) {
		var actions = [];
		var srcWidth = config.WIDTH;
		var srcHeight = config.HEIGHT;

		var scale = Math.max(targetWidth / srcWidth, targetHeight / srcHeight);
		var scaledW = Math.round(srcWidth * scale);
		var scaledH = Math.round(srcHeight * scale);
		var cropX = Math.round((scaledW - targetWidth) / 2);
		var cropY = Math.round((scaledH - targetHeight) / 2);

		for (var i in config.layers) {
			var layer = config.layers[i];
			if (layer.type !== 'image') continue;
			if (layer.width == null || layer.height == null) continue;

			var canvas = this.Base_layers.convert_layer_to_canvas(layer.id, true, false);
			var newLayerW = Math.round(layer.width * scale);
			var newLayerH = Math.round(layer.height * scale);

			var tmp = document.createElement('canvas');
			tmp.width = newLayerW;
			tmp.height = newLayerH;
			await this.pica.resize(canvas, tmp, {alpha: true});

			var newX = Math.round(layer.x * scale) - cropX;
			var newY = Math.round(layer.y * scale) - cropY;

			actions.push(new app.Actions.Update_layer_image_action(tmp, layer.id));
			actions.push(new app.Actions.Update_layer_action(layer.id, {
				x: newX,
				y: newY,
				width: newLayerW,
				height: newLayerH,
				width_original: newLayerW,
				height_original: newLayerH,
			}));
		}

		return actions;
	}
}

export default Image_size_class;
