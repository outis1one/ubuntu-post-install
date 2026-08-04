import app from './../app.js';
import config from './../config.js';
import Base_tools_class from './../core/base-tools.js';
import Base_layers_class from './../core/base-layers.js';
import Dialog_class from './../libs/popup.js';
import GUI_tools_class from './../core/gui/gui-tools.js';
import File_my_library_class from './../modules/file/my_library.js';

var instance = null;

class Shape_class extends Base_tools_class {

	constructor(ctx) {
		super();

		//singleton
		if (instance) {
			return instance;
		}
		instance = this;

		this.Base_layers = new Base_layers_class();
		this.GUI_tools = new GUI_tools_class();
		this.POP = new Dialog_class();
		this.My_library = new File_my_library_class();
		this.ctx = ctx;
		this.name = 'shape';
		this.layer = {};
		this.preview_width = 150;
		this.preview_height = 120;
		this.activeTab = 'shapes'; // 'shapes' or 'library'

		this.set_events();
	}

	set_events() {
		document.addEventListener('keydown', (event) => {
			var code = event.keyCode;
			if (this.Helper.is_input(event.target))
				return;

			if (code == 72) {
				//H
				this.show_shapes();
			}
		}, false);
	}

	load() {

	}

	on_activate() {
		this.show_shapes();
	}

	async show_shapes(){
		var _this = this;

		// Build tabs HTML
		var tabsHtml = '<div class="shape-tabs">';
		tabsHtml += '<button class="shape-tab active" data-tab="shapes">Built-in Shapes</button>';
		tabsHtml += '<button class="shape-tab" data-tab="library">My Library</button>';
		tabsHtml += '</div>';

		// Build shapes HTML
		var shapesHtml = '<div class="tab-content shapes-content">';
		var data = this.get_shapes();

		for (var i in data) {
			shapesHtml += '<div class="item">';
			shapesHtml += '	<canvas id="c_' + data[i].key + '" width="' + this.preview_width + '" height="'
				+ this.preview_height + '" class="effectsPreview" data-key="'
				+ data[i].key + '"></canvas>';
			shapesHtml += '<div class="preview-item-title">' + data[i].title + '</div>';
			shapesHtml += '</div>';
		}
		for (var i = 0; i < 4; i++) {
			shapesHtml += '<div class="item"></div>';
		}
		shapesHtml += '</div>';

		// Build library HTML placeholder
		var libraryHtml = '<div class="tab-content library-content" style="display:none;">';
		libraryHtml += '<div class="library-loading">Loading library...</div>';
		libraryHtml += '</div>';

		var settings = {
			title: 'Shapes & Library',
			className: 'wide',
			on_load: function (params, popup) {
				// Add tabs
				var tabsNode = document.createElement("div");
				tabsNode.innerHTML = tabsHtml;
				popup.el.querySelector('.dialog_content').insertBefore(tabsNode, popup.el.querySelector('.dialog_content').firstChild);

				// Add shapes container
				var shapesNode = document.createElement("div");
				shapesNode.classList.add('flex-container');
				shapesNode.innerHTML = shapesHtml;
				popup.el.querySelector('.dialog_content').appendChild(shapesNode);

				// Add library container
				var libraryNode = document.createElement("div");
				libraryNode.innerHTML = libraryHtml;
				popup.el.querySelector('.dialog_content').appendChild(libraryNode);

				// Tab click events
				var tabs = popup.el.querySelectorAll('.shape-tab');
				tabs.forEach(function(tab) {
					tab.addEventListener('click', function() {
						var targetTab = this.dataset.tab;

						// Update active tab
						tabs.forEach(t => t.classList.remove('active'));
						this.classList.add('active');

						// Show/hide content
						var shapesContent = popup.el.querySelector('.shapes-content');
						var libraryContent = popup.el.querySelector('.library-content');

						if (targetTab === 'shapes') {
							shapesContent.style.display = '';
							libraryContent.style.display = 'none';
						} else {
							shapesContent.style.display = 'none';
							libraryContent.style.display = '';
							_this.loadLibraryContent(libraryContent);
						}
					});
				});

				// Shape click events
				var targets = popup.el.querySelectorAll('.item canvas');
				for (var i = 0; i < targets.length; i++) {
					targets[i].addEventListener('click', function (event) {
						_this.GUI_tools.activate_tool(this.dataset.key);
						_this.POP.hide();
					});
				}
			},
		};
		this.POP.show(settings);

		//sleep, lets wait till DOM is finished
		await new Promise(r => setTimeout(r, 10));

		//draw demo thumbs
		for (var i in data) {
			var function_name = 'demo';
			var canvas = document.getElementById('c_'+data[i].key);
			var ctx = canvas.getContext("2d");

			if(typeof data[i].object[function_name] == "undefined")
				continue;

			data[i].object[function_name](ctx, 20, 20, this.preview_width - 40, this.preview_height - 40, null);
		}
	}

	/**
	 * Load library content into the library tab
	 */
	loadLibraryContent(container) {
		var _this = this;

		this.My_library.getAllAssets(function(assets) {
			var html = '';

			if (assets.length === 0) {
				html = '<div class="library-empty">';
				html += '<p>Your library is empty.</p>';
				html += '<p>Use <strong>File > My Library > Save to Library</strong> to add assets.</p>';
				html += '</div>';
			} else {
				// Group by category
				var categories = {};
				assets.forEach(function(asset) {
					var cat = asset.category || 'General';
					if (!categories[cat]) categories[cat] = [];
					categories[cat].push(asset);
				});

				html = '<div class="library-browser">';
				html += '<div class="library-categories">';

				for (var cat in categories) {
					html += '<div class="library-category">';
					html += '<h3>' + cat + ' (' + categories[cat].length + ')</h3>';
					html += '<div class="library-items">';

					categories[cat].forEach(function(asset) {
						html += '<div class="library-item" data-id="' + asset.id + '">';
						html += '<img src="' + asset.thumbnail + '" alt="' + asset.name + '" title="' + asset.name + '">';
						html += '<div class="library-item-name">' + asset.name + '</div>';
						html += '<div class="library-item-actions">';
						html += '<button class="insert-btn" data-id="' + asset.id + '">Insert</button>';
						html += '<button class="delete-btn" data-id="' + asset.id + '">Delete</button>';
						html += '</div>';
						html += '</div>';
					});

					html += '</div></div>';
				}

				html += '</div></div>';
			}

			container.innerHTML = html;

			// Add event handlers for library items
			container.querySelectorAll('.insert-btn').forEach(function(btn) {
				btn.addEventListener('click', function(e) {
					e.stopPropagation();
					var id = parseInt(this.dataset.id);
					_this.My_library.insertAsset(id);
					_this.POP.hide();
				});
			});

			container.querySelectorAll('.delete-btn').forEach(function(btn) {
				btn.addEventListener('click', function(e) {
					e.stopPropagation();
					var id = parseInt(this.dataset.id);
					if (confirm('Delete this asset?')) {
						_this.My_library.deleteAsset(id, function() {
							_this.loadLibraryContent(container);
						});
					}
				});
			});

			// Double-click to insert
			container.querySelectorAll('.library-item').forEach(function(item) {
				item.addEventListener('dblclick', function() {
					var id = parseInt(this.dataset.id);
					_this.My_library.insertAsset(id);
					_this.POP.hide();
				});
			});
		});
	}

	render(ctx, layer) {

	}

	get_shapes(){
		var list = [];

		for (var i in this.Base_gui.GUI_tools.tools_modules) {
			var object = this.Base_gui.GUI_tools.tools_modules[i];
			if (object.full_key.indexOf("shapes/") == -1 )
				continue;

			list.push(object);
		}

		list.sort(function(a, b) {
			var nameA = a.title.toUpperCase();
			var nameB = b.title.toUpperCase();
			if (nameA < nameB) return -1;
			if (nameA > nameB) return 1;
			return 0;
		});

		return list;
	}

}

export default Shape_class;
