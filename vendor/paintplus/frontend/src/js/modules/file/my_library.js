/**
 * My Library - Save and reuse your own assets (clip art, templates, etc.)
 * Assets are stored in browser's IndexedDB for persistence
 */

import app from './../../app.js';
import config from './../../config.js';
import Dialog_class from './../../libs/popup.js';
import Base_layers_class from './../../core/base-layers.js';
import alertify from './../../../../node_modules/alertifyjs/build/alertify.min.js';

var instance = null;

// IndexedDB setup
const DB_NAME = 'miniPaintLibrary';
const DB_VERSION = 1;
const STORE_NAME = 'assets';

class File_my_library_class {

    constructor() {
        if (instance) {
            return instance;
        }
        instance = this;

        this.POP = new Dialog_class();
        this.Base_layers = new Base_layers_class();
        this.db = null;

        this.initDB();
    }

    /**
     * Initialize IndexedDB
     */
    initDB() {
        var _this = this;

        var request = indexedDB.open(DB_NAME, DB_VERSION);

        request.onerror = function(event) {
            console.error('IndexedDB error:', event);
        };

        request.onsuccess = function(event) {
            _this.db = event.target.result;
        };

        request.onupgradeneeded = function(event) {
            var db = event.target.result;

            if (!db.objectStoreNames.contains(STORE_NAME)) {
                var store = db.createObjectStore(STORE_NAME, { keyPath: 'id', autoIncrement: true });
                store.createIndex('name', 'name', { unique: false });
                store.createIndex('category', 'category', { unique: false });
                store.createIndex('created', 'created', { unique: false });
            }
        };
    }

    /**
     * Save current layer as a library asset
     */
    save_to_library() {
        var _this = this;

        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer to save');
            return;
        }

        var settings = {
            title: 'Save to My Library',
            params: [
                {
                    name: "name",
                    title: "Asset Name:",
                    value: config.layer.name || "My Asset"
                },
                {
                    name: "category",
                    title: "Category:",
                    value: "General",
                    values: ["General", "Shapes", "Borders", "Icons", "Templates", "Text Elements", "Backgrounds", "Other"]
                },
                {
                    name: "description",
                    title: "Description:",
                    value: ""
                }
            ],
            on_finish: function (params) {
                _this.do_save_to_library(params);
            },
        };
        this.POP.show(settings);
    }

    /**
     * Save current selection to library (uses mask if available)
     */
    save_selection_to_library() {
        var _this = this;

        if (!window.smartSelectMask || !window.smartSelectMask.canvas) {
            alertify.error('No selection. Use a selection tool first.');
            return;
        }

        if (config.layer.type != 'image') {
            alertify.error('Please select an image layer');
            return;
        }

        var settings = {
            title: 'Save Selection to Library',
            params: [
                {
                    name: "name",
                    title: "Asset Name:",
                    value: "Selection Asset"
                },
                {
                    name: "category",
                    title: "Category:",
                    value: "General",
                    values: ["General", "Shapes", "Borders", "Icons", "Templates", "Text Elements", "Backgrounds", "Other"]
                },
                {
                    name: "description",
                    title: "Description:",
                    value: ""
                }
            ],
            on_finish: function (params) {
                _this.do_save_selection_to_library(params);
            },
        };
        this.POP.show(settings);
    }

    do_save_to_library(params) {
        var _this = this;

        // Get canvas from current layer
        var canvas = this.Base_layers.convert_layer_to_canvas(config.layer.id, true, false);

        // Create thumbnail (max 150px)
        var thumbCanvas = document.createElement('canvas');
        var maxSize = 150;
        var scale = Math.min(maxSize / canvas.width, maxSize / canvas.height);
        thumbCanvas.width = Math.round(canvas.width * scale);
        thumbCanvas.height = Math.round(canvas.height * scale);
        var thumbCtx = thumbCanvas.getContext('2d');
        thumbCtx.drawImage(canvas, 0, 0, thumbCanvas.width, thumbCanvas.height);

        var asset = {
            name: params.name,
            category: params.category,
            description: params.description,
            width: canvas.width,
            height: canvas.height,
            data: canvas.toDataURL('image/png'),
            thumbnail: thumbCanvas.toDataURL('image/png'),
            created: new Date().toISOString()
        };

        this.saveAsset(asset, function() {
            alertify.success('Saved "' + params.name + '" to library!');
        });
    }

    do_save_selection_to_library(params) {
        var _this = this;
        var layer = config.layer;
        var maskCanvas = window.smartSelectMask.canvas;

        // Create canvas with just the selected pixels
        var canvas = document.createElement('canvas');
        canvas.width = layer.width_original;
        canvas.height = layer.height_original;
        var ctx = canvas.getContext('2d');

        ctx.drawImage(layer.link, 0, 0);
        ctx.globalCompositeOperation = 'destination-in';
        ctx.drawImage(maskCanvas, 0, 0);

        // Find bounds of selection
        var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        var data = imageData.data;
        var minX = canvas.width, minY = canvas.height, maxX = 0, maxY = 0;

        for (var y = 0; y < canvas.height; y++) {
            for (var x = 0; x < canvas.width; x++) {
                var i = (y * canvas.width + x) * 4;
                if (data[i + 3] > 0) {
                    minX = Math.min(minX, x);
                    minY = Math.min(minY, y);
                    maxX = Math.max(maxX, x);
                    maxY = Math.max(maxY, y);
                }
            }
        }

        // Crop to selection bounds
        var cropWidth = maxX - minX + 1;
        var cropHeight = maxY - minY + 1;
        var croppedCanvas = document.createElement('canvas');
        croppedCanvas.width = cropWidth;
        croppedCanvas.height = cropHeight;
        var croppedCtx = croppedCanvas.getContext('2d');
        croppedCtx.drawImage(canvas, minX, minY, cropWidth, cropHeight, 0, 0, cropWidth, cropHeight);

        // Create thumbnail
        var thumbCanvas = document.createElement('canvas');
        var maxSize = 150;
        var scale = Math.min(maxSize / cropWidth, maxSize / cropHeight);
        thumbCanvas.width = Math.round(cropWidth * scale);
        thumbCanvas.height = Math.round(cropHeight * scale);
        var thumbCtx = thumbCanvas.getContext('2d');
        thumbCtx.drawImage(croppedCanvas, 0, 0, thumbCanvas.width, thumbCanvas.height);

        var asset = {
            name: params.name,
            category: params.category,
            description: params.description,
            width: cropWidth,
            height: cropHeight,
            data: croppedCanvas.toDataURL('image/png'),
            thumbnail: thumbCanvas.toDataURL('image/png'),
            created: new Date().toISOString()
        };

        this.saveAsset(asset, function() {
            alertify.success('Saved selection "' + params.name + '" to library!');
        });
    }

    saveAsset(asset, callback) {
        if (!this.db) {
            alertify.error('Database not ready, please try again');
            return;
        }

        var transaction = this.db.transaction([STORE_NAME], 'readwrite');
        var store = transaction.objectStore(STORE_NAME);
        var request = store.add(asset);

        request.onsuccess = function() {
            if (callback) callback();
        };

        request.onerror = function(event) {
            alertify.error('Error saving asset');
            console.error('Save error:', event);
        };
    }

    /**
     * Browse and insert assets from library
     */
    browse_library() {
        var _this = this;

        this.getAllAssets(function(assets) {
            _this.showLibraryBrowser(assets);
        });
    }

    getAllAssets(callback) {
        if (!this.db) {
            alertify.error('Database not ready');
            callback([]);
            return;
        }

        var transaction = this.db.transaction([STORE_NAME], 'readonly');
        var store = transaction.objectStore(STORE_NAME);
        var request = store.getAll();

        request.onsuccess = function(event) {
            callback(event.target.result || []);
        };

        request.onerror = function() {
            callback([]);
        };
    }

    showLibraryBrowser(assets) {
        var _this = this;

        if (assets.length === 0) {
            alertify.warning('Your library is empty. Save some assets first!');
            return;
        }

        // Group by category
        var categories = {};
        assets.forEach(function(asset) {
            var cat = asset.category || 'General';
            if (!categories[cat]) categories[cat] = [];
            categories[cat].push(asset);
        });

        // Build HTML for the browser
        var html = '<div class="library-browser">';
        html += '<div class="library-categories">';

        for (var cat in categories) {
            html += '<div class="library-category">';
            html += '<h3>' + cat + '</h3>';
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

        // Show in dialog
        var settings = {
            title: 'My Library (' + assets.length + ' assets)',
            params: [],
            html: html,
            className: 'wide',
            on_load: function(el) {
                // Add click handlers
                el.querySelectorAll('.insert-btn').forEach(function(btn) {
                    btn.addEventListener('click', function(e) {
                        e.stopPropagation();
                        var id = parseInt(this.dataset.id);
                        _this.insertAsset(id);
                        _this.POP.hide();
                    });
                });

                el.querySelectorAll('.delete-btn').forEach(function(btn) {
                    btn.addEventListener('click', function(e) {
                        e.stopPropagation();
                        var id = parseInt(this.dataset.id);
                        if (confirm('Delete this asset?')) {
                            _this.deleteAsset(id, function() {
                                alertify.success('Asset deleted');
                                _this.POP.hide();
                            });
                        }
                    });
                });

                // Double-click to insert
                el.querySelectorAll('.library-item').forEach(function(item) {
                    item.addEventListener('dblclick', function() {
                        var id = parseInt(this.dataset.id);
                        _this.insertAsset(id);
                        _this.POP.hide();
                    });
                });
            }
        };

        this.POP.show(settings);
    }

    insertAsset(id) {
        var _this = this;

        var transaction = this.db.transaction([STORE_NAME], 'readonly');
        var store = transaction.objectStore(STORE_NAME);
        var request = store.get(id);

        request.onsuccess = function(event) {
            var asset = event.target.result;
            if (asset) {
                _this.createLayerFromAsset(asset);
            }
        };
    }

    createLayerFromAsset(asset) {
        var _this = this;

        var img = new Image();
        img.onload = function() {
            // Insert as new layer
            var params = {
                x: Math.round((config.WIDTH - asset.width) / 2),
                y: Math.round((config.HEIGHT - asset.height) / 2),
                width: asset.width,
                height: asset.height,
                width_original: asset.width,
                height_original: asset.height,
                type: 'image',
                name: asset.name,
                data: asset.data
            };

            app.State.do_action(
                new app.Actions.Bundle_action('insert_library_asset', 'Insert Library Asset', [
                    new app.Actions.Insert_layer_action(params)
                ])
            );

            alertify.success('Inserted "' + asset.name + '"');
        };
        img.src = asset.data;
    }

    deleteAsset(id, callback) {
        var transaction = this.db.transaction([STORE_NAME], 'readwrite');
        var store = transaction.objectStore(STORE_NAME);
        var request = store.delete(id);

        request.onsuccess = function() {
            if (callback) callback();
        };
    }

    /**
     * Export library to JSON file (backup)
     */
    export_library() {
        var _this = this;

        this.getAllAssets(function(assets) {
            if (assets.length === 0) {
                alertify.warning('Library is empty');
                return;
            }

            var data = JSON.stringify(assets, null, 2);
            var blob = new Blob([data], { type: 'application/json' });
            var url = URL.createObjectURL(blob);

            var a = document.createElement('a');
            a.href = url;
            a.download = 'my-library-backup.json';
            a.click();

            URL.revokeObjectURL(url);
            alertify.success('Library exported!');
        });
    }

    /**
     * Import library from JSON file
     */
    import_library() {
        var _this = this;

        var input = document.createElement('input');
        input.type = 'file';
        input.accept = '.json';

        input.onchange = function(e) {
            var file = e.target.files[0];
            if (!file) return;

            var reader = new FileReader();
            reader.onload = function(event) {
                try {
                    var assets = JSON.parse(event.target.result);

                    if (!Array.isArray(assets)) {
                        alertify.error('Invalid library file');
                        return;
                    }

                    var imported = 0;
                    assets.forEach(function(asset) {
                        // Remove id so it gets auto-assigned
                        delete asset.id;
                        _this.saveAsset(asset, function() {
                            imported++;
                            if (imported === assets.length) {
                                alertify.success('Imported ' + imported + ' assets!');
                            }
                        });
                    });

                } catch (err) {
                    alertify.error('Error parsing library file');
                    console.error(err);
                }
            };
            reader.readAsText(file);
        };

        input.click();
    }
}

export default File_my_library_class;
