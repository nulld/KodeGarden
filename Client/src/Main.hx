package;

import haxe.ui.HaxeUIApp;
import haxe.ui.macros.ComponentMacros;
import haxe.Timer;
import haxe.ui.containers.TabView;
import haxe.ui.containers.ScrollView;
import haxe.ui.containers.Box;
import haxe.ui.containers.HBox;
import haxe.ui.containers.ListView;
import haxe.ui.containers.dialogs.DialogButton;
import haxe.ui.components.TextArea;
import haxe.ui.components.Button;
import haxe.ui.components.Image;
import haxe.ui.components.Label;
import haxe.ui.core.Screen;
import custom.MonacoEditor;
import dialogs.AddResourceDialog;
import js.Browser;
import js.html.ArrayBuffer;
import js.html.FileReader;
import haxe.ui.ToolkitAssets;
import haxe.ui.containers.dialogs.DialogOptions;

class Main {
    private static var _tabs:TabView;
    private static var _fileList:ListView;
    private static var _log:ScrollView;
    private static var _currentEditor:MonacoEditor; 
    private static var sha:String = '28773311499a4587e77e02c3d083fcd52c117eee';

    public static var sourceList = []; // for validation
    public static var shaderList = []; // for validation
    public static var assetList = []; // for validation
    
    public static function main() {
        Server.log = logMessage;
        var app = new HaxeUIApp();
        app.ready(function() {
            // TODO: pretty crappy way to "preload" images - create preloader as part of HaxeUIApp (ready only called once loaded - should be optional)
            ToolkitAssets.instance.getImage("img/play-button_grey.png", function(e) {});
            ToolkitAssets.instance.getImage("img/repeat_grey.png", function(e) {});
            ToolkitAssets.instance.getImage("img/attachment_grey.png", function(e) {});
            ToolkitAssets.instance.getImage("img/plus_grey.png", function(e) {});
            ToolkitAssets.instance.getImage("img/file_grey.png", function(e) {});
            ToolkitAssets.instance.getImage("img/layers_grey.png", function(e) {});
            ToolkitAssets.instance.getImage("img/picture_grey.png", function(e) {});

            if (Browser.window.location.hash.length > 1) {
                sha = Browser.window.location.hash.substr(1);
            }

            Browser.window.onhashchange = function() {
                var newSha = Browser.window.location.hash.substr(1);
                if (newSha != sha) {
                    Browser.window.location.reload();
                }
            };
            
            var main = ComponentMacros.buildComponent("assets/ui/main.xml");

            _fileList = main.findComponent("fileList");
            _fileList.onChange = function(e) {
                _tabs.pageIndex = _fileList.selectedIndex;
            }

            _tabs = main.findComponent("tabs");
            _tabs.onBeforeChange = onBeforeTabChange;
            _tabs.onChange = onTabChange;

            _log = main.findComponent("log");

            main.findComponent("clearLog", Button).onClick = function(e) {
                _log.clearContents();
            }

            main.findComponent("copyLog", Button).onClick = function(e) {
                var data = "";
                for (c in _log.contents.childComponents) {
                    data += c.findComponent(Label).text + "\n";
                }

                // gotta love html/js!
                var temp = Browser.document.createTextAreaElement();
                temp.style.border = 'none';
                temp.style.outline = 'none';
                temp.style.boxShadow = 'none';
                temp.style.background = 'transparent';
                Browser.document.body.appendChild(temp);
                temp.value = data;
                temp.select();

                try {
                    var successful = Browser.document.execCommand('copy');
                } catch (e:Dynamic) { }

                Browser.document.body.removeChild(temp);
            }

            main.findComponent("buttonInject", Button).onClick = function(e) {
                if (_currentEditor != null) {
                    inject(_tabs.selectedButton.text, _currentEditor.text);
                    _currentEditor.dirty = false;
                }
            };

            main.findComponent("buttonRestart", Button).onClick = function(e) {
                if (_currentEditor != null) {
                    build(_tabs.selectedButton.text, _currentEditor.text);
                    _currentEditor.dirty = false;
                }
            };

            main.findComponent("buttonDownload", Button).onClick = function(e) {
                Server.download(sha).handle(function(e:Dynamic) {
                    Browser.window.location.replace('/archives/' + sha + '.zip');
                });
            }

            main.findComponent("addResourceButton", Button).onClick = function(e) {
                startAddResource();
            }

            app.addComponent(main);

            var scriptElement = Browser.document.createScriptElement();
            scriptElement.onload = function(e) {
                trace("kha.js loaded");
                WorkerKha.instance.load('/projects/' + sha + '/khaworker.js');
                refreshResources(sha);
                logMessage("KodeGarden ready", false);
            }
            scriptElement.src = "kha.js";
            Browser.document.body.appendChild(scriptElement);

            app.start();
        });
    }

    private static function startAddResource() {
        var dialog = new AddResourceDialog();
        var options = {
            title: "Add Resource",
            buttons: []
        }
        var dialogContainer = null;
        Screen.instance.showDialog(dialog, options, function(b) {
            if (b.id == "confirm") {
                switch (dialog.resourceType) {
                    case "Source":
                        var sourceFile = dialog.sourceFile.text;
                        if (StringTools.endsWith(sourceFile, ".hx") == false) {
                            sourceFile += ".hx";
                        }
                        var box = createSourceEditor(sourceFile, "package;\n");
                        _tabs.addComponent(box);
                    
                        _fileList.dataSource.add({name: sourceFile, icon: "img/file_grey.png"});
                        _fileList.selectedIndex = _tabs.pageCount - 1;
                        sourceList.push(sourceFile);

                        Server.addSource(sha, sourceFile).handle(function(newSha:Dynamic) {
                            sha = newSha;
                            WorkerKha.instance.load('/projects/' + newSha + '/khaworker.js');
                            Browser.window.history.pushState('', '', '#' + sha);
                        });

                    case "Shader":
                        var shaderFile = dialog.shaderFile.text + dialog.shaderType.text;
                        var box = createShaderEditor(shaderFile, "void main() {\n\n}\n");
                        _tabs.addComponent(box);
                    
                        _fileList.dataSource.add({name: shaderFile, icon: "img/layers_grey.png"});
                        _fileList.selectedIndex = _tabs.pageCount - 1;
                        shaderList.push(shaderFile);

                        Server.addShader(sha, shaderFile).handle(function(newSha:Dynamic) {
                            sha = newSha;
                            WorkerKha.instance.load('/projects/' + newSha + '/khaworker.js');
                            Browser.window.history.pushState('', '', '#' + sha);
                        });

                    case "Asset":
                        var reader:FileReader = new FileReader();
                        reader.onload = function(upload) {
                            var box = createAssetViewer(dialog.assetFile.file.name);
                            _tabs.addComponent(box);
                            
                            _fileList.dataSource.add({name: dialog.assetFile.file.name, icon: IconUtil.assetIcon(dialog.assetFile.file.name)});
                            _fileList.selectedIndex = _tabs.pageCount - 1;
                            assetList.push(dialog.assetFile.file.name);
                            
                            var buffer:ArrayBuffer = upload.target.result;
                            Server.addAsset(sha, dialog.assetFile.file.name, buffer).handle(function(newSha:Dynamic) {
                                sha = newSha;
                                WorkerKha.instance.load('/projects/' + newSha + '/khaworker.js');
                                Browser.window.history.pushState('', '', '#' + sha);
                            });
                        }
                        reader.readAsArrayBuffer(dialog.assetFile.file);
                }
            }
        });
    }

    private static function build(name:String, content:String) {
        if (StringTools.endsWith(name, ".hx")) {
            Server.setSource(sha, name, content).handle(function(newSha:Dynamic) {
                sha = newSha;
                WorkerKha.instance.load('/projects/' + newSha + '/khaworker.js');
                Browser.window.history.pushState('', '', '#' + sha);
            });
        } else {
            Server.setShader(sha, name, content).handle(function(newSha:Dynamic) {
                sha = newSha;
                WorkerKha.instance.load('/projects/' + newSha + '/khaworker.js');
                Browser.window.history.pushState('', '', '#' + sha);
            });
        }
    }

    private static function inject(name:String, content:String) {
        if (StringTools.endsWith(name, ".hx")) {
            Server.setSource(sha, name, content).handle(function(newSha:Dynamic) {
                sha = newSha;
                WorkerKha.instance.inject('/projects/' + newSha + '/khaworker.js');
                Browser.window.history.pushState('', '', '#' + sha);
            });
        } else {
            Server.setShader(sha, name, content).handle(function(newSha:Dynamic) {
                sha = newSha;
                WorkerKha.instance.injectShader('/projects/' + newSha + '/khaworker.js');
                Browser.window.history.pushState('', '', '#' + sha);
            });
        }

    }

    private static function onBeforeTabChange(e) {
        if (_tabs.selectedPage == null) {
            return;
        }

        var selectedEditor = _tabs.selectedPage.findComponent(MonacoEditor, true);
        if (selectedEditor != null && selectedEditor.dirty == true) {
            inject( _tabs.selectedButton.text, selectedEditor.text);
            selectedEditor.dirty = false;
        }
     }

    private static function onTabChange(e) {
        if (_tabs.selectedPage == null) {
            return;
        }
        var selectedEditor = _tabs.selectedPage.findComponent(MonacoEditor, true);
        _currentEditor = selectedEditor;
        _fileList.selectedIndex = _tabs.pageIndex;
    }

    private static function refreshResources(sha:String) {
        _tabs.removeAllTabs();

        Server.sources(sha).handle(function(sources:Array<String>) {
            sourceList = sources;
            for (source in sources) {
                _fileList.dataSource.add({name: source, icon: "img/file_grey.png"});

                Server.source(sha, source).handle(function(content:Dynamic) {

                    var box = createSourceEditor(source, content);
                    _tabs.addComponent(box);
                });
            }

            if (_fileList.selectedIndex == -1) {
                _fileList.selectedIndex = 0;
            }

            Server.shaders(sha).handle(function(shaders:Array<String>) {
                shaderList = shaders;
                for (shader in shaders) {
                    _fileList.dataSource.add({name: shader, icon: "img/layers_grey.png"});

                    Server.shader(sha, shader).handle(function(content:Dynamic) {
                        var box = createShaderEditor(shader, content);
                        _tabs.addComponent(box);
                    });
                }

                Server.assets(sha).handle(function(assets:Array<String>) {
                    assetList = assets;
                    for (asset in assets) {
                        _fileList.dataSource.add({name: asset, icon: IconUtil.assetIcon(asset)});

                        var box = createAssetViewer(asset);
                        _tabs.addComponent(box);
                    }
                });
            });
        });
    }

    private static function createSourceEditor(name:String, content:String = "") {
        var box = new Box();
        box.styleNames = "editor";
        box.percentWidth = box.percentHeight = 100;
        box.text = name;
        box.icon = "img/file_grey.png";

        var editor = new MonacoEditor();
        editor.percentWidth = editor.percentHeight = 100;
        editor.text = content;
        box.addComponent(editor);

        return box;
    }

    private static function createShaderEditor(name:String, content:String = "") {
        var box = new Box();
        box.styleNames = "editor";
        box.percentWidth = box.percentHeight = 100;
        box.text = name;
        box.icon = "img/layers_grey.png";

        var editor = new MonacoEditor();
        editor.percentWidth = editor.percentHeight = 100;
        editor.text = content;
        box.addComponent(editor);

        return box;
    }

    private static function createAssetViewer(name:String) {
        var box = new Box();
        box.styleNames = "editor";
        box.percentWidth = box.percentHeight = 100;
        box.text = name;
        box.icon = IconUtil.assetIcon(name);

        return box;
    }

    private static function logMessage(message:String, error:Bool = false) {
        var hbox = new HBox();
        hbox.percentWidth = 100;

        var label = new Label();
        label.percentWidth = 100;
        label.text = message;
        if (error == true) {
            label.styleNames = "error";
        }

        hbox.addComponent(label);

        _log.addComponent(hbox);
        _log.vscrollPos = _log.vscrollMax + 200;
    }
}