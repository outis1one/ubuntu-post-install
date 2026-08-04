/**
 * miniPaint - https://github.com/viliusle/miniPaint
 * author: Vilius L.
 */

//css
import './../css/reset.css';
import './../css/utility.css';
import './../css/component.css';
import './../css/layout.css';
import './../css/menu.css';
import './../css/print.css';
import './../../node_modules/alertifyjs/build/css/alertify.min.css';
//js
import app from './app.js';
import config from './config.js';
import './core/components/index.js';
import Base_gui_class from './core/base-gui.js';
import Base_layers_class from './core/base-layers.js';
import Base_tools_class from './core/base-tools.js';
import Base_state_class from './core/base-state.js';
import Base_search_class from './core/base-search.js';
import File_open_class from './modules/file/open.js';
import File_save_class from './modules/file/save.js';
import * as Actions from './actions/index.js';
import { mountProviderBadge } from './core/components/provider-badge.js';

window.addEventListener('load', function (e) {
	// Initiate app
	var Layers = new Base_layers_class();
	var Base_tools = new Base_tools_class(true);
	var GUI = new Base_gui_class();
	var Base_state = new Base_state_class();
	var File_open = new File_open_class();
	var File_save = new File_save_class();
	var Base_search = new Base_search_class();

	// Register singletons in app module
	app.Actions = Actions;
	app.Config = config;
	app.FileOpen = File_open;
	app.FileSave = File_save;
	app.GUI = GUI;
	app.Layers = Layers;
	app.State = Base_state;
	app.Tools = Base_tools;

	// Register as global for quick or external access
	window.Layers = Layers;
	window.AppConfig = config;
	window.State = Base_state;
	window.FileOpen = File_open;
	window.FileSave = File_save;

	// Render all
	GUI.init();
	Layers.init();

	// Mount provider badge in the tools panel footer
	mountProviderBadge(document.getElementById('tools_container') || document.body);

	// Collapse right-panel Colors section by default (compact color swatch on left toolbar instead)
	_collapseColorsPanel();
	// Mount compact foreground/background color swatches at bottom of left toolbar
	_mountToolbarColorSwatch();
}, false);

function _collapseColorsPanel() {
	var toggle = document.querySelector('[data-target="toggle_colors"]');
	var panel  = document.getElementById('toggle_colors');
	if (toggle && panel) {
		// Only collapse if user hasn't explicitly expanded it (no saved cookie)
		var Helper = { getCookie: (k) => { var m = document.cookie.match('(^|;)\\s*' + k + '\\s*=\\s*([^;]+)'); return m ? m.pop() : null; } };
		if (Helper.getCookie('toggle_colors') !== '1') {
			panel.classList.add('hidden');
			toggle.classList.add('toggled');
		}
	}
}

function _mountToolbarColorSwatch() {
	var toolbar = document.getElementById('tools_container');
	if (!toolbar) return;

	// Spacer to push swatch to bottom
	var spacer = document.createElement('div');
	spacer.style.cssText = 'flex:1;min-height:8px;width:100%;';
	toolbar.appendChild(spacer);

	// Foreground / background color squares (click to open full color picker)
	var wrap = document.createElement('div');
	wrap.id  = 'toolbar_color_swatch';
	wrap.title = 'Foreground / Background color — click to open color picker';
	wrap.style.cssText = 'position:relative;width:30px;height:30px;margin:4px 0 4px 5px;cursor:pointer;flex-shrink:0;';
	wrap.innerHTML = `
		<div id="tc_bg" style="position:absolute;right:0;bottom:0;width:20px;height:20px;
			border:1px solid #555;background:#000;border-radius:3px;"></div>
		<div id="tc_fg" style="position:absolute;left:0;top:0;width:20px;height:20px;
			border:1px solid #777;background:#008000;border-radius:3px;"></div>`;
	toolbar.appendChild(wrap);

	// Keep swatch in sync with config.COLOR
	function _syncSwatch() {
		var fg = document.getElementById('tc_fg');
		var bg = document.getElementById('tc_bg');
		if (fg) fg.style.background = window.config && config.COLOR ? config.COLOR : '#008000';
	}
	setInterval(_syncSwatch, 250);

	// Click → open the right-side color panel
	wrap.addEventListener('click', function () {
		var panel  = document.getElementById('toggle_colors');
		var toggle = document.querySelector('[data-target="toggle_colors"]');
		if (!panel) return;
		var hidden = panel.classList.contains('hidden');
		if (hidden) {
			panel.classList.remove('hidden');
			if (toggle) toggle.classList.remove('toggled');
			// Scroll right panel to top so color picker is visible
			var sidebar = document.querySelector('.sidebar_right');
			if (sidebar) sidebar.scrollTop = 0;
		} else {
			panel.classList.add('hidden');
			if (toggle) toggle.classList.add('toggled');
		}
	});
}
