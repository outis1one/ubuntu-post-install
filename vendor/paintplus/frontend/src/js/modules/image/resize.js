import app from './../../app.js';
import config from './../../config.js';
import Base_layers_class from './../../core/base-layers.js';
import Base_gui_class from './../../core/base-gui.js';
import Dialog_class from './../../libs/popup.js';
import ImageFilters_class from './../../libs/imagefilters.js';
import Hermite_class from 'hermite-resize';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';
import Pica from './../../../../node_modules/pica/dist/pica.js';
import Helper_class from './../../libs/helpers.js';
import Tools_settings_class from './../tools/settings.js';
import { metaDefaults as textMetaDefaults } from '../../tools/text.js';

var instance = null;

class Image_resize_class {

	constructor() {
		//singleton
		if (instance) {
			return instance;
		}
		instance = this;

		this.Base_layers = new Base_layers_class();
		this.Base_gui = new Base_gui_class();
		this.POP = new Dialog_class();
		this.ImageFilters = ImageFilters_class;
		this.Hermite = new Hermite_class();
		this.Tools_settings = new Tools_settings_class();
		this.pica = Pica();
		this.Helper = new Helper_class();
		this._lastUnits = 'pixels';

		this.set_events();
	}

	set_events() {
		document.addEventListener('keydown', (event) => {
			var code = event.keyCode;
			if (this.Helper.is_input(event.target))
				return;

			if (code == 82 && event.ctrlKey != true && event.metaKey != true) {
				//R - resize
				this.resize();
				event.preventDefault();
			}
		}, false);
	}

	resize() {
		var _this = this;
		var savedUnits = this.Tools_settings.get_setting('default_units');
		var resolution = this.Tools_settings.get_setting('resolution');

		var displayUnits = (savedUnits === 'inches') ? 'inches' : 'pixels';
		this._lastUnits = displayUnits;

		var width = this.Helper.get_user_unit(config.WIDTH, displayUnits, resolution);
		var height = this.Helper.get_user_unit(config.HEIGHT, displayUnits, resolution);

		var settings = {
			title: 'Resize',
			params: [
				{name: "units", title: "Units:", value: displayUnits, values: ["pixels", "inches"]},
				{name: "width", title: "Width:", value: '', placeholder: width, comment: displayUnits},
				{name: "height", title: "Height:", value: '', placeholder: height, comment: displayUnits},
				{name: "width_percent", title: "Width (%):", value: '', placeholder: 100, comment: "%"},
				{name: "height_percent", title: "Height (%):", value: '', placeholder: 100, comment: "%"},
				{name: "mode", title: "Mode:", values: ["Lanczos", "Hermite", "Basic"]},
				{name: "crop_to_fill", title: "Crop to fill:", value: false},
				{name: "sharpen", title: "Sharpen:", value: false},
				{name: "layers", title: "Layers:", values: ["All", "Active"], value: "All"},
			],
			on_change: function(params) {
				_this.units_change_handler(params);
			},
			on_finish: function (params) {
				_this.do_resize(params);
			},
		};
		this.POP.show(settings);

		document.getElementById("pop_data_width").select();
	}

	/**
	 * Called on any dialog field change; reacts only when the units radio switches.
	 * Updates width/height placeholders and labels, and persists the choice globally.
	 */
	units_change_handler(params) {
		var units = params.units;
		if (units === this._lastUnits) return;

		this._lastUnits = units;
		var resolution = this.Tools_settings.get_setting('resolution');

		// Persist so Canvas Size and other dialogs open with the same units
		const unitShort = {pixels: 'px', inches: '"', centimeters: 'cm', millimetres: 'mm'};
		this.Tools_settings.save_setting('default_units', units);
		this.Tools_settings.save_setting('default_units_short', unitShort[units] || units);

		var newWidth = this.Helper.get_user_unit(config.WIDTH, units, resolution);
		var newHeight = this.Helper.get_user_unit(config.HEIGHT, units, resolution);

		var widthInput = document.getElementById('pop_data_width');
		var heightInput = document.getElementById('pop_data_height');
		if (widthInput) {
			widthInput.placeholder = newWidth;
			widthInput.value = '';
		}
		if (heightInput) {
			heightInput.placeholder = newHeight;
			heightInput.value = '';
		}

		var wComment = widthInput ? widthInput.nextElementSibling : null;
		var hComment = heightInput ? heightInput.nextElementSibling : null;
		if (wComment && wComment.classList.contains('field_comment')) wComment.textContent = units;
		if (hComment && hComment.classList.contains('field_comment')) hComment.textContent = units;
	}

	async do_resize(params) {
		//validate
		if (isNaN(params.width) && isNaN(params.height) && isNaN(params.width_percent) && isNaN(params.height_percent)) {
			alertify.error('Missing at least 1 size parameter.');
			return false;
		}

		// Crop-to-fill: scale to cover then center-crop; requires both dimensions
		if (params.crop_to_fill == true) {
			if (isNaN(params.width) || isNaN(params.height)) {
				alertify.error('Crop to fill requires both Width and Height.');
				return false;
			}
			if (params.layers == 'All') {
				return this.do_resize_crop_fill(params);
			}
		}

		// Build a list of actions to execute for resize
		let actions = [];

		if (params.layers == 'All') {
			//resize all layers
			var skips = 0;
			for (var i in config.layers) {
				try {
					actions = actions.concat(await this.resize_layer(config.layers[i], params));
				} catch (error) {
					skips++;
				}
			}
			if (skips > 0) {
				alertify.error(skips + ' layer(s) were skipped.');
			}
			actions = actions.concat(this.resize_gui(params));
		}
		else {
			//only active
			actions = actions.concat(await this.resize_layer(config.layer, params));
		}
		return app.State.do_action(
			new app.Actions.Bundle_action('resize_layers', 'Resize Layers', actions)
		);
	}

	/**
	 * Resize all image layers using cover-scale then center-crop so the subject
	 * looks the same regardless of target aspect ratio (no stretching).
	 */
	async do_resize_crop_fill(params) {
		var units = params.units || this.Tools_settings.get_setting('default_units');
		var resolution = this.Tools_settings.get_setting('resolution');

		var targetWidth = this.Helper.get_internal_unit(parseFloat(params.width), units, resolution);
		var targetHeight = this.Helper.get_internal_unit(parseFloat(params.height), units, resolution);
		targetWidth = parseInt(targetWidth);
		targetHeight = parseInt(targetHeight);

		if (!targetWidth || !targetHeight || targetWidth < 1 || targetHeight < 1) {
			alertify.error('Invalid dimensions for crop to fill.');
			return;
		}

		var srcWidth = config.WIDTH;
		var srcHeight = config.HEIGHT;

		// Cover scale: image fills target, excess is cropped from center
		var scale = Math.max(targetWidth / srcWidth, targetHeight / srcHeight);
		var scaledW = Math.round(srcWidth * scale);
		var scaledH = Math.round(srcHeight * scale);
		var cropX = Math.round((scaledW - targetWidth) / 2);
		var cropY = Math.round((scaledH - targetHeight) / 2);

		var mode = params.mode;
		var sharpen = params.sharpen;
		let actions = [];

		for (var i in config.layers) {
			var layer = config.layers[i];
			if (layer.type !== 'image') continue;
			if (layer.width == null || layer.height == null) continue;

			var canvas = this.Base_layers.convert_layer_to_canvas(layer.id, true, false);
			var newLayerW = Math.round(layer.width * scale);
			var newLayerH = Math.round(layer.height * scale);

			var useMode = mode;
			if (useMode == "Hermite" && (newLayerW > canvas.width || newLayerH > canvas.height)) {
				useMode = "Lanczos";
			}

			var tmp = document.createElement('canvas');
			tmp.width = newLayerW;
			tmp.height = newLayerH;

			if (useMode == "Lanczos") {
				await this.pica.resize(canvas, tmp, {alpha: true});
			} else if (useMode == "Hermite") {
				tmp.getContext('2d').drawImage(canvas, 0, 0);
				this.Hermite.resample_single(tmp, newLayerW, newLayerH, true);
			} else {
				tmp.getContext('2d').drawImage(canvas, 0, 0, newLayerW, newLayerH);
			}

			if (sharpen == true) {
				var ctx = tmp.getContext('2d');
				var imageData = ctx.getImageData(0, 0, tmp.width, tmp.height);
				ctx.putImageData(this.ImageFilters.Sharpen(imageData, 1), 0, 0);
			}

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

		// Update canvas dimensions to exact target
		actions = actions.concat([
			new app.Actions.Prepare_canvas_action('undo'),
			new app.Actions.Update_config_action({
				WIDTH: targetWidth,
				HEIGHT: targetHeight,
			}),
			new app.Actions.Prepare_canvas_action('do'),
		]);

		return app.State.do_action(
			new app.Actions.Bundle_action('resize_layers', 'Resize Layers', actions)
		);
	}

	/**
	 * Generates actions that will resize layer (image, text, vector), returns a promise that rejects on failure.
	 *
	 * @param {object} layer
	 * @param {object} params
	 * @returns {Promise<object>} Returns array of actions to perform
	 */
	async resize_layer(layer, params) {
		var units = params.units || this.Tools_settings.get_setting('default_units');
		var resolution = this.Tools_settings.get_setting('resolution');
		var mode = params.mode;
		var width = parseFloat(params.width);
		var height = parseFloat(params.height);
		var width_100 = parseInt(params.width_percent);
		var height_100 = parseInt(params.height_percent);
		var canvas_width = layer.width;
		var canvas_height = layer.height;
		var sharpen = params.sharpen;
		var _this = this;

		//convert units
		if (isNaN(width) == false){
			width = this.Helper.get_internal_unit(width, units, resolution);
		}
		if (isNaN(height) == false){
			height = this.Helper.get_internal_unit(height, units, resolution);
		}

		//if dimension with percent provided
		if (isNaN(width) && isNaN(height)) {
			if (isNaN(width_100) == false) {
				width = Math.round(config.WIDTH * width_100 / 100);
				canvas_width = Math.round(config.WIDTH * width_100 / 100);
			}
			if (isNaN(height_100) == false) {
				height = Math.round(config.HEIGHT * height_100 / 100);
				canvas_height = Math.round(config.HEIGHT * height_100 / 100);
			}
		}

		//if only 1 dimension was provided
		if (isNaN(width) || isNaN(height)) {
			var ratio = layer.width / layer.height;
			var canvas_ratio = config.WIDTH / config.HEIGHT;
			if (isNaN(width))
				width = Math.round(height * ratio);
				canvas_width = Math.round(canvas_height * canvas_ratio);
			if (isNaN(height))
				height = Math.round(width / ratio);
				canvas_height = Math.round(canvas_width / canvas_ratio);
		}

		let new_x = params.layers == 'All' ? Math.round(layer.x * width / config.WIDTH) : layer.x;
		let new_y = params.layers == 'All' ? Math.round(layer.y * height / config.HEIGHT) : layer.y;
		let xratio = width / config.WIDTH;
		let yratio = height / config.HEIGHT;

		//is text
		if (layer.type == 'text') {
			let data = JSON.parse(JSON.stringify(layer.data));
			for (let line of data) {
				for (let span of line) {
					span.meta.size = Math.ceil((span.meta.size || textMetaDefaults.size) * xratio);
					span.meta.stroke_size = parseFloat((0.1 * Math.round((span.meta.stroke_size != null ? span.meta.stroke_size : textMetaDefaults.stroke_size) * xratio / 0.1)).toFixed(1));
					span.meta.kerning = Math.ceil((span.meta.kerning || textMetaDefaults.kerning) * xratio);
				}
			}

			// Return actions
			return [
				new app.Actions.Update_layer_action(layer.id, {
					x: new_x,
					y: new_y,
					data,
					width: layer.width * xratio,
					height: layer.height * yratio
				})
			];
		}

		//is vector
		else if (layer.is_vector == true && layer.width != null && layer.height != null) {
			// Return actions
			return [
				new app.Actions.Update_layer_action(layer.id, {
					x: new_x,
					y: new_y,
					width: layer.width * xratio,
					height: layer.height * yratio
				})
			];
		}

		//only images supported at this point
		else if (layer.type != 'image') {
			//error - no support
			alertify.error('Layer must be vector or image (convert it to raster).');
			throw new Error('Layer is not compatible with resize');
		}

		//get canvas from layer
		var canvas = this.Base_layers.convert_layer_to_canvas(layer.id, true, false);
		var ctx = canvas.getContext("2d");

		//validate
		if (mode == "Hermite" && (width > canvas.width || height > canvas.height)) {
			alertify.warning('Scaling up is not supported in Hermite, using Lanczos.');
			mode = "Lanczos";
		}

		//resize
		if (mode == "Lanczos") {
			//Pica resize with max quality

			var tmp_data = document.createElement("canvas");
			tmp_data.width = width;
			tmp_data.height = height;

			await this.pica.resize(canvas, tmp_data, {
				alpha: true,
			})
			.then((result) => {
				ctx.clearRect(0, 0, canvas.width, canvas.height);
				canvas.width = width;
				canvas.height = height;
				ctx.drawImage(tmp_data, 0, 0, width, height);
			});
		}
		else if (mode == "Hermite") {
			//Hermite resample
			this.Hermite.resample_single(canvas, width, height, true);
		}
		else {
			//simple resize
			var tmp_data = document.createElement("canvas");
			tmp_data.width = canvas.width;
			tmp_data.height = canvas.height;
			tmp_data.getContext("2d").drawImage(canvas, 0, 0);

			ctx.clearRect(0, 0, canvas.width, canvas.height);
			canvas.width = width;
			canvas.height = height;

			ctx.drawImage(tmp_data, 0, 0, width, height);
		}

		if (sharpen == true) {
			var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
			var filtered = _this.ImageFilters.Sharpen(imageData, 1);	//add effect
			ctx.putImageData(filtered, 0, 0);
		}

		// Return actions
		return [
			new app.Actions.Update_layer_image_action(canvas, layer.id),
			new app.Actions.Update_layer_action(layer.id, {
				x: new_x,
				y: new_y,
				width: canvas.width,
				height: canvas.height,
				width_original: canvas.width,
				height_original: canvas.height
			})
		];
	}

	resize_gui(params) {
		var units = params.units || this.Tools_settings.get_setting('default_units');
		var resolution = this.Tools_settings.get_setting('resolution');

		var width = parseFloat(params.width);
		var height = parseFloat(params.height);
		var width_100 = parseInt(params.width_percent);
		var height_100 = parseInt(params.height_percent);

		//convert units
		if (isNaN(width) == false){
			width = this.Helper.get_internal_unit(width, units, resolution);
		}
		if (isNaN(height) == false){
			height = this.Helper.get_internal_unit(height, units, resolution);
		}

		//if dimension with percent provided
		if (isNaN(width) && isNaN(height)) {
			if (isNaN(width_100) == false) {
				width = Math.round(config.WIDTH * width_100 / 100);
			}
			if (isNaN(height_100) == false) {
				height = Math.round(config.HEIGHT * height_100 / 100);
			}
		}

		//if only 1 dimension was provided
		if (isNaN(width) || isNaN(height)) {
			var ratio = config.WIDTH / config.HEIGHT;
			if (isNaN(width))
				width = Math.round(height * ratio);
			if (isNaN(height))
				height = Math.round(width / ratio);
		}

		return [
			new app.Actions.Prepare_canvas_action('undo'),
			new app.Actions.Update_config_action({
				WIDTH: parseInt(width),
				HEIGHT: parseInt(height)
			}),
			new app.Actions.Prepare_canvas_action('do')
		];
	}

}

export default Image_resize_class;
