import config from './../../config.js';
import Dialog_class from './../../libs/popup.js';

class Help_about_class {

	constructor() {
		this.POP = new Dialog_class();
	}

	//about
	about() {
		var email = 'www.viliusl@gmail.com';

		var settings = {
			title: 'About',
			params: [
				{title: "", html: '<img style="width:64px;" class="about-logo" alt="" src="images/logo-colors.png" />'},
				{title: "Name:", html: '<span class="about-name">PaintPlus</span>'},
				{title: "Version:", value: VERSION},
				{title: "Description:", value: "Layer-based image editor with AI tools."},
				{title: "", html: '<hr style="margin:8px 0;border-color:#444;">'},
				{title: "Base:", html: '<a href="https://github.com/viliusle/miniPaint" target="_blank">miniPaint</a> by ViliusL'},
				{title: "AI Erase:", html: 'LaMa (Samsung Research) via <a href="https://github.com/enesmsahin/simple-lama-inpainting" target="_blank">simple-lama-inpainting</a>'},
				{title: "Bg Removal:", html: '<a href="https://github.com/danielgatis/rembg" target="_blank">rembg</a> / U2Net / OpenCV'},
				{title: "Smart Select:", html: '<a href="https://github.com/facebookresearch/segment-anything" target="_blank">SAM</a> (Meta AI)'},
				{title: "Remote AI:", html: 'InvokeAI · ComfyUI · OpenAI (user-configured)'},
				{title: "", html: '<hr style="margin:8px 0;border-color:#444;">'},
				{title: "GitHub:", html: '<a href="https://github.com/outis1one/EditmaskwithAI" target="_blank">outis1one/EditmaskwithAI</a>'},
			],
		};
		this.POP.show(settings);
	}

}

export default Help_about_class;
