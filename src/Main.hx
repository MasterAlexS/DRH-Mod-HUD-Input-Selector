package mods.hud_input_selector;

import brain.logger.Logger;
import facade.DBFacade;
import openfl.events.Event;
import openfl.events.KeyboardEvent;
import openfl.events.MouseEvent;
import mods.api.Context;
import mods.api.Mod;
import mods.api.Dictionaries;
import uI.hud.starlingConverted.StarlingHud;
import starling.textures.Texture;
import starling.display.Image;
import starling.display.DisplayObject;
import starling.display.DisplayObjectContainer;
import brain.assetRepository.ImageAsset;
import brain.assetRepository.AssetLoadingComponent;

/**
 * HUD Input Selector Mod
 * Allows player to customize in-game HUD button prompts:
 * 
 * 1. BUTTONS USED:
 *    - Default: primary keyboard key binding
 *    - Alt: secondary / alternate keyboard key binding configured in game
 * 
 * 2. BUTTON PROMPTS:
 *    - Auto Detect: switches dynamically based on the last used device (keyboard/mouse vs. controller)
 *    - Keyboard: forces keyboard prompts on the HUD at all times
 *    - Controller: forces controller prompts on the HUD at all times
 * 
 * 3. CONTROLLER STYLE:
 *    - Auto Detect
 *    - Console styles (DualSense, DualShock 4, DualShock 3, Xbox, Switch, etc.)
 * 
 * 4. KEYBOARD STYLE:
 *    - Text: standard text labels (Z, X, C, 1, 2, Space)
 *    - Dark Keys: keycap glyphs on dark background
 *    - Light Keys: keycap glyphs on light background
 */
class Main extends Mod {
	var context:Context;
	var facade:Null<DBFacade>;

	var buttonsUsed:String = "default"; // "default" or "alt"
	var promptMode:String = "auto"; // "auto", "kbm", "controller"
	var controllerStyle:String = "auto"; // "auto", "ps5", ...
	var keyboardStyle:String = "kbm_dark"; // "kbm_dark", "kbm_light", "text"

	var lastUsedDevice:String = "kbm"; // "kbm" or "controller"
	var customSettingsRegistered:Bool = false;
	var nativeSettingsRegistered:Bool = false;
	var initializedState:Bool = false;
	var isSyncingHUD:Bool = false;
	var currentPromptState:String = ""; // "kbm", "controller"

	var lastMouseX:Float = -1;
	var lastMouseY:Float = -1;
	var lastControllerTime:Float = 0;
	var lastEnforcedHud:Dynamic = null;
	var lastEnforcedDevice:String = "";
	var lastEnforcedView:Dynamic = null;
	var lastEnforcedGeneration:Int = -1;
	var lastStateMachineState:Dynamic = null;
	var lastSyncTimestamp:Float = 0;

	var nativeButtonsChoice:Dynamic = null;
	var nativePromptChoice:Dynamic = null;
	var nativeControllerStyleChoice:Dynamic = null;
	var nativeKeyboardStyleChoice:Dynamic = null;

	override public function init(context:Context):Void {
		this.context = context;
	}

	override public function ready(context:Context):Void {
		facade = context.core.facade;
		if (facade == null) return;

		// Initial device detection: start with kbm unless controller has active input right now
		try {
			lastUsedDevice = isAnyControllerActive() ? "controller" : "kbm";
		} catch (eDet:Dynamic) {
			lastUsedDevice = "kbm";
		}

		// Listen for frame updates and physical input events
		if (context != null && context.overlay != null) {
			context.overlay.addEventListener(Event.ENTER_FRAME, onFrame);
			var stage:Dynamic = context.overlay.stage;
			if (stage == null && facade != null) stage = Reflect.field(facade, "stageRef");
			if (stage != null) {
				try {
					stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown, true);
					stage.addEventListener(MouseEvent.MOUSE_DOWN, onMouseDown, true);
					stage.addEventListener(MouseEvent.MOUSE_MOVE, onMouseMove, true);
					stage.addEventListener(MouseEvent.MOUSE_WHEEL, onMouseWheel, true);
				} catch (eSt:Dynamic) {}
			}
		}

		// Listen to SteamInput controller events
		try {
			var em:Dynamic = Reflect.field(facade, "eventManager");
			if (em == null) em = Reflect.field(facade, "mEventManager");
			if (em != null) {
				Reflect.callMethod(em, Reflect.field(em, "addEventListener"), ["OnSteamInputButtonPressedEvent", onControllerAction]);
				Reflect.callMethod(em, Reflect.field(em, "addEventListener"), ["OnSteamInputButtonReleasedEvent", onControllerAction]);
				Reflect.callMethod(em, Reflect.field(em, "addEventListener"), ["OnSteamInputGlyphsChanged", onGlyphsChanged]);
				Reflect.callMethod(em, Reflect.field(em, "addEventListener"), ["ControllerConnectionChangedEvent", onControllerChanged]);
			}
		} catch (eEM:Dynamic) {}

		// Listen to in-game key binding changes (Options -> Controls)
		try {
			var kb:Dynamic = Reflect.field(facade, "keyBindings");
			if (kb == null) kb = Reflect.field(facade, "mKeyBindings");
			if (kb != null) {
				Reflect.callMethod(kb, Reflect.field(kb, "addChangeListener"), [onKeyBindingsChanged]);
			}
		} catch (eKB:Dynamic) {}

		// Ensure custom LocalSteamInputGlyphs and aliases are in place
		ensureCustomLocalGlyphs();

		// 1. Always register settings natively with Mod API (ensures options exist in game catalog)
		tryRegisterNativeApiSettings();

		// 2. Explicitly register 'input_hud' category with CustomSettingsApi if available
		try {
			var cls:Dynamic = Type.resolveClass("mods.custom_settings_api.CustomSettingsApi");
			if (cls != null) {
				var fnAddCat = Reflect.field(cls, "addCategory");
				if (fnAddCat != null) {
					Reflect.callMethod(cls, fnAddCat, ["input_hud", "INPUT HUD", "hud_input_selector"]);
				}
			}
		} catch (eCat:Dynamic) {}
		try {
			var bridge:Dynamic = getCustomSettingsBridge();
			if (bridge != null) {
				invokeBridge(bridge, "addCategory", ["input_hud", "INPUT HUD", "hud_input_selector"]);
			}
		} catch (eBridge:Dynamic) {}

		// Listen for floor, hero, and town lifecycle events from mod API
		try {
			context.onFloorEnter(function(floor) {
				triggerFloorTransitionSync();
			});
			context.onHeroSpawned(function(hero) {
				triggerFloorTransitionSync();
			});
			context.onTownEnter(function() {
				triggerFloorTransitionSync();
			});
		} catch (eEvents:Dynamic) {}

		// Apply initial state
		syncHUD(true);

		context.log("HUD Input Selector ready.");
	}

	function triggerFloorTransitionSync():Void {
		lastEnforcedHud = null;
		lastEnforcedDevice = "";
		lastEnforcedView = null;
		initializedState = false;
		syncHUD(true);
	}

	override public function dispose():Void {
		if (facade != null) {
			if (context != null && context.overlay != null) {
				try {
					context.overlay.removeEventListener(Event.ENTER_FRAME, onFrame);
				} catch (e1:Dynamic) {}
				var stage:Dynamic = context.overlay.stage;
				if (stage == null && facade != null) stage = Reflect.field(facade, "stageRef");
				if (stage != null) {
					try {
						stage.removeEventListener(KeyboardEvent.KEY_DOWN, onKeyDown, true);
						stage.removeEventListener(MouseEvent.MOUSE_DOWN, onMouseDown, true);
						stage.removeEventListener(MouseEvent.MOUSE_MOVE, onMouseMove, true);
						stage.removeEventListener(MouseEvent.MOUSE_WHEEL, onMouseWheel, true);
					} catch (e2:Dynamic) {}
				}
			}
			try {
				var em:Dynamic = Reflect.field(facade, "eventManager");
				if (em == null) em = Reflect.field(facade, "mEventManager");
				if (em != null) {
					Reflect.callMethod(em, Reflect.field(em, "removeEventListener"), ["OnSteamInputButtonPressedEvent", onControllerAction]);
					Reflect.callMethod(em, Reflect.field(em, "removeEventListener"), ["OnSteamInputButtonReleasedEvent", onControllerAction]);
					Reflect.callMethod(em, Reflect.field(em, "removeEventListener"), ["OnSteamInputGlyphsChanged", onGlyphsChanged]);
					Reflect.callMethod(em, Reflect.field(em, "removeEventListener"), ["ControllerConnectionChangedEvent", onControllerChanged]);
				}
			} catch (eEM:Dynamic) {}
			try {
				var kb:Dynamic = Reflect.field(facade, "keyBindings");
				if (kb == null) kb = Reflect.field(facade, "mKeyBindings");
				if (kb != null) {
					Reflect.callMethod(kb, Reflect.field(kb, "removeChangeListener"), [onKeyBindingsChanged]);
				}
			} catch (e3:Dynamic) {}
		}

		facade = null;
	}

	function onKeyBindingsChanged(action:String):Void {
		try {
			syncHUD(true);
		} catch (e:Dynamic) {}
	}

	function onFrame(event:Event):Void {
		if (facade == null) return;
		try {
			// Ensure steamInputManager does not auto-wipe origins every 250ms
			freezeSteamInputOrigins();

			// Ensure settings are registered natively
			if (!nativeSettingsRegistered) {
				tryRegisterNativeApiSettings();
			}

			// Ensure custom LocalSteamInputGlyphs is attached to steamInputManager
			ensureCustomLocalGlyphs();

			// Poll gamepad inputs and sync device in auto mode
			pollGamepad();

			// Enforce prompt state if game or screen transition changed it
			enforceHUDState();
		} catch (e:Dynamic) {}
	}

	static inline function getTimestamp():Float {
		return Date.now().getTime();
	}

	function onControllerAction(e:Dynamic = null):Void {
		try {
			lastControllerTime = getTimestamp();
			handleInputDevice("controller");
		} catch (e:Dynamic) {}
	}

	function isAnyControllerActive():Bool {
		if (facade == null) return false;
		var sim:Dynamic = Reflect.field(facade, "steamInputManager");
		if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
		if (sim == null) return false;
		try {
			// 1. Direct analog movement check on steamInputManager
			for (actName in ["game_movement", "move", "movement"]) {
				try {
					var moveVec:Dynamic = Reflect.callMethod(sim, Reflect.field(sim, "getAnalogAction"), [actName]);
					if (moveVec != null) {
						var vx:Float = Reflect.field(moveVec, "x") != null ? Reflect.field(moveVec, "x") : 0.0;
						var vy:Float = Reflect.field(moveVec, "y") != null ? Reflect.field(moveVec, "y") : 0.0;
						if ((vx * vx + vy * vy) > 0.16) {
							return true;
						}
					}
				} catch (eAm:Dynamic) {}
			}

			var list:Dynamic = Reflect.field(sim, "mConnectedSteamControllers");
			if (list != null && Reflect.field(list, "length") > 0) {
				var count:Int = Reflect.field(list, "length");
				for (i in 0...count) {
					var c:Dynamic = list[i];
					if (c == null) continue;

					// Check digital buttons pressed this frame or held down
					try {
						for (fieldName in ["mPressedDigitalButtons", "mHeldDigitalButtons", "pressedDigitalButtons", "heldDigitalButtons"]) {
							var dict:Dynamic = Reflect.field(c, fieldName);
							if (dict != null) {
								var keys:Array<Dynamic> = Dictionaries.keys(dict);
								if (keys != null && keys.length > 0) {
									return true;
								}
							}
						}
					} catch (eHeld:Dynamic) {}

					// Check deliberate analog stick movement
					try {
						var analogs:Dynamic = Reflect.field(c, "mAnalogActionsNamesToVector3D");
						if (analogs == null) analogs = Reflect.field(c, "analogInputs");
						if (analogs == null) analogs = Reflect.field(c, "mAnalogInputs");
						if (analogs != null) {
							for (actName in ["game_movement", "move", "movement"]) {
								var vec:Dynamic = Dictionaries.get(analogs, actName);
								if (vec != null) {
									var vx:Float = Reflect.field(vec, "x") != null ? Reflect.field(vec, "x") : 0.0;
									var vy:Float = Reflect.field(vec, "y") != null ? Reflect.field(vec, "y") : 0.0;
									if ((vx * vx + vy * vy) > 0.16) {
										return true;
									}
								}
							}
						}
					} catch (eAnalog:Dynamic) {}
				}
			}
		} catch (eOuter:Dynamic) {}
		return false;
	}

	function isAnyControllerConnected():Bool {
		if (facade == null) return false;
		var sim:Dynamic = Reflect.field(facade, "steamInputManager");
		if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
		if (sim == null) return false;
		try {
			var list:Dynamic = Reflect.field(sim, "mConnectedSteamControllers");
			if (list != null && Reflect.field(list, "length") > 0) return true;
		} catch (e:Dynamic) {}
		return false;
	}

	function onKeyDown(event:KeyboardEvent):Void {
		try {
			// If a controller button was physically pressed in the last 60ms,
			// ignore this event as it was dispatched by DRH's KeyboardEventSpoofer
			if (getTimestamp() - lastControllerTime < 60) {
				return;
			}
			handleInputDevice("kbm");
		} catch (e:Dynamic) {}
	}

	function onMouseDown(event:MouseEvent):Void {
		try {
			if (getTimestamp() - lastControllerTime < 60) return;
			handleInputDevice("kbm");
		} catch (e:Dynamic) {}
	}

	function onMouseWheel(event:MouseEvent):Void {
		try {
			if (getTimestamp() - lastControllerTime < 60) return;
			handleInputDevice("kbm");
		} catch (e:Dynamic) {}
	}

	function onMouseMove(event:MouseEvent):Void {
		try {
			if (lastMouseX < 0) {
				lastMouseX = event.stageX;
				lastMouseY = event.stageY;
				return;
			}
			var dx = event.stageX - lastMouseX;
			var dy = event.stageY - lastMouseY;
			if ((dx * dx + dy * dy) > 25) {
				lastMouseX = event.stageX;
				lastMouseY = event.stageY;
				if (getTimestamp() - lastControllerTime < 60) return;
				handleInputDevice("kbm");
			}
		} catch (e:Dynamic) {}
	}

	function onGlyphsChanged(event:Event):Void {
		// Only re-sync if controllerStyle is auto and physically changed, but never recursively in a loop
		if (isSyncingHUD) return;
		try {
			if (promptMode == "auto" && controllerStyle == "auto") {
				syncHUD(false);
			}
		} catch (e:Dynamic) {}
	}

	function onControllerChanged(event:Event):Void {
		if (isSyncingHUD) return;
		try {
			var state = getDesiredPromptState();
			if (state == "kbm") {
				syncHUD(true);
				return;
			}
			if (promptMode == "controller" || promptMode == "kbm") {
				syncHUD(true);
			} else {
				// "auto" mode
				var isReady:Bool = false;
				try {
					var sim:Dynamic = Reflect.field(facade, "steamInputManager");
					if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
					if (sim != null && Reflect.field(sim, "isSteamInputReady") == true) isReady = true;
				} catch (eR:Dynamic) {}
				if (!isReady && lastUsedDevice == "controller") {
					lastUsedDevice = "kbm";
				}
				syncHUD(true);
			}
		} catch (e:Dynamic) {}
	}

	function pollGamepad():Void {
		if (promptMode != "auto") return;
		if (facade == null) return;

		try {
			// Check direct controller activity only (do not use mCursorHidden as DRH leaves it true until mouse moves)
			var controllerActive = isAnyControllerActive();
			if (controllerActive) {
				lastControllerTime = getTimestamp();
				handleInputDevice("controller");
			}
		} catch (e:Dynamic) {}
	}

	function handleInputDevice(device:String):Void {
		if (lastUsedDevice == device) return;
		lastUsedDevice = device;
		if (promptMode == "auto") {
			syncHUD(false);
		}
	}

	function getDesiredPromptState():String {
		return switch (promptMode) {
			case "kbm": "kbm";
			case "controller": "controller";
			case "auto": (lastUsedDevice == "controller") ? "controller" : "kbm";
			default: (lastUsedDevice == "controller") ? "controller" : "kbm";
		};
	}

	function syncHUD(force:Bool = false):Void {
		if (facade == null || isSyncingHUD) return;
		var now = Date.now().getTime();
		if (!force && initializedState && (now - lastSyncTimestamp < 250)) return;
		isSyncingHUD = true;
		try {
			lastSyncTimestamp = now;
			var state = getDesiredPromptState();
			if (!force && initializedState && currentPromptState == state) {
				isSyncingHUD = false;
				return;
			}
			initializedState = true;
			currentPromptState = state;

			if (state == "controller") {
				applyControllerPrompts();
			} else {
				// "kbm"
				if (keyboardStyle == "text") {
					applyKBMPrompts();
				} else {
					applyKeyboardGlyphPrompts(keyboardStyle);
				}
			}
		} catch (e:Dynamic) {}
		isSyncingHUD = false;
	}

	function getLocalGlyphPathsDict():Dynamic {
		if (facade == null) return null;
		var sim:Dynamic = Reflect.field(facade, "steamInputManager");
		if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
		if (sim == null) return null;
		var lg:Dynamic = Reflect.field(sim, "mLocalGlyphs");
		if (lg != null) {
			try {
				Reflect.callMethod(lg, Reflect.field(lg, "getGlyphPath"), ["dummy_init_path.png", ""]);
			} catch (e:Dynamic) {}
			return Reflect.field(lg, "mGlyphPathsByName");
		}
		return null;
	}

	function freezeSteamInputOrigins():Void {
		if (facade == null) return;
		try {
			var sim:Dynamic = Reflect.field(facade, "steamInputManager");
			if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
			if (sim != null) {
				Reflect.setField(sim, "mActionOriginsUpdateTime", 2000000000000.0);
			}
		} catch (e:Dynamic) {}
	}

	function restoreLocaleBusterString():Void {
		try {
			var locCls:Dynamic = Type.resolveClass("facade.Locale");
			if (locCls != null) {
				var defTbl:Dynamic = Reflect.field(locCls, "mDefaultStringTable");
				if (defTbl != null && defTbl.strings != null) {
					Reflect.setField(defTbl.strings, "PRESS_BUSTER_BUTTON_CONTROLLER", "PRESS   ");
					Reflect.setField(defTbl.strings, "PRESS_BUSTER_BUTTON_KEYBOARD", "PRESS ");
				}
				var overTbl:Dynamic = Reflect.field(locCls, "mOverrideStringTable");
				if (overTbl != null && overTbl.strings != null) {
					Reflect.setField(overTbl.strings, "PRESS_BUSTER_BUTTON_CONTROLLER", "PRESS   ");
					Reflect.setField(overTbl.strings, "PRESS_BUSTER_BUTTON_KEYBOARD", "PRESS ");
				}
			}
		} catch (eLoc:Dynamic) {}
	}

	function killStarlingGlyphTask(sHud:Dynamic):Void {
		if (sHud == null) return;
		try {
			var task:Dynamic = Reflect.field(sHud, "mGlyphTask");
			if (task != null) {
				try {
					if (Reflect.field(task, "destroy") != null) Reflect.callMethod(task, Reflect.field(task, "destroy"), []);
				} catch (e1:Dynamic) {}
				try {
					Reflect.setField(task, "callback", null);
				} catch (e2:Dynamic) {}
				try {
					var work:Dynamic = Reflect.field(sHud, "mWork");
					if (work != null) {
						var wlm:Dynamic = Reflect.field(work, "mWorkLoopManager");
						if (wlm != null) {
							Reflect.callMethod(wlm, Reflect.field(wlm, "removeDoLater"), [task]);
						}
					}
				} catch (e3:Dynamic) {}
				Reflect.setField(sHud, "mGlyphTask", null);
			}
		} catch (e:Dynamic) {}
	}

	function detachStarlingListeners(sHud:Dynamic):Void {
		if (sHud == null) return;
		try {
			var sEvents:Dynamic = Reflect.field(sHud, "mEvents");
			if (sEvents != null) {
				Reflect.callMethod(sEvents, Reflect.field(sEvents, "removeListener"), ["OnSteamInputGlyphsChanged"]);
				Reflect.callMethod(sEvents, Reflect.field(sEvents, "removeListener"), ["ControllerConnectionChangedEvent"]);
			}
			killStarlingGlyphTask(sHud);
		} catch (e:Dynamic) {}
	}

	function resolvePhysicalPath(path:String):String {
		if (path == null || path == "") return "";
		try {
			var sysCls:Dynamic = Type.resolveClass("sys.FileSystem");
			if (sysCls != null) {
				var existsFn:Dynamic = Reflect.field(sysCls, "exists");
				if (existsFn != null && Reflect.callMethod(sysCls, existsFn, [path]) == true) {
					return path;
				}
			}
		} catch (eSys:Dynamic) {}
		try {
			var clean = path;
			if (StringTools.startsWith(clean, "./")) clean = clean.substr(2);
			if (StringTools.startsWith(clean, ".\\")) clean = clean.substr(2);
			var alCls:Dynamic = Type.resolveClass("brain.assetRepository.AssetLoader");
			if (alCls != null) {
				var f:Dynamic = Reflect.callMethod(alCls, Reflect.field(alCls, "resolveFile"), [clean]);
				if (f != null && Reflect.field(f, "exists") == true) {
					var np:String = Reflect.field(f, "nativePath");
					if (np != null && np != "") return np;
				}
			}
		} catch (eAL:Dynamic) {}
		return path;
	}

	function getCloseNode(sHud:Dynamic):Dynamic {
		if (sHud == null) return null;
		try {
			var view:Dynamic = Reflect.field(sHud, "mView");
			if (view != null && Reflect.field(view, "node") != null) {
				var nd = Reflect.callMethod(view, Reflect.field(view, "node"), ["close"]);
				if (nd != null) return nd;
			}
		} catch (e1:Dynamic) {}
		try {
			if (Reflect.field(sHud, "node") != null) {
				var nd = Reflect.callMethod(sHud, Reflect.field(sHud, "node"), ["close"]);
				if (nd != null) return nd;
			}
		} catch (e2:Dynamic) {}
		return null;
	}

	function getOptionsViewRoot(sHud:Dynamic):Dynamic {
		if (sHud == null) return null;
		try {
			var optView:Dynamic = Reflect.field(sHud, "mOptionsView");
			if (optView != null) {
				var r:Dynamic = null;
				try { r = Reflect.getProperty(optView, "root"); } catch (e1:Dynamic) {}
				if (r == null) {
					try { r = Reflect.field(optView, "mRoot"); } catch (e2:Dynamic) {}
				}
				if (r == null) {
					try { r = Reflect.field(optView, "root"); } catch (e3:Dynamic) {}
				}
				if (r == null && Reflect.field(optView, "get_root") != null) {
					try { r = Reflect.callMethod(optView, Reflect.field(optView, "get_root"), []); } catch (e4:Dynamic) {}
				}
				return r;
			}
		} catch (e:Dynamic) {}
		return null;
	}

	function getChatLogRoot(sHud:Dynamic):Dynamic {
		if (sHud == null) return null;
		try {
			var chatPrompt:Dynamic = Reflect.field(sHud, "mChatPrompt");
			if (chatPrompt != null) {
				var logBtn:Dynamic = null;
				try { logBtn = Reflect.getProperty(chatPrompt, "logButton"); } catch (e1:Dynamic) {}
				if (logBtn == null) {
					try { logBtn = Reflect.field(chatPrompt, "mLog"); } catch (e2:Dynamic) {}
				}
				if (logBtn == null) {
					try { logBtn = Reflect.field(chatPrompt, "logButton"); } catch (e3:Dynamic) {}
				}
				if (logBtn != null) {
					var r:Dynamic = null;
					try { r = Reflect.getProperty(logBtn, "root"); } catch (e4:Dynamic) {}
					if (r == null) {
						try { r = Reflect.field(logBtn, "mRoot"); } catch (e5:Dynamic) {}
					}
					if (r == null) {
						try { r = Reflect.field(logBtn, "root"); } catch (e6:Dynamic) {}
					}
					if (r == null && Reflect.field(logBtn, "get_root") != null) {
						try { r = Reflect.callMethod(logBtn, Reflect.field(logBtn, "get_root"), []); } catch (e7:Dynamic) {}
					}
					return r;
				}
			}
		} catch (e:Dynamic) {}
		return null;
	}

	function setStarlingActionGlyph(sHud:Dynamic, action:String, owner:Dynamic, path:String, x:Float, y:Float, size:Float = 25, height:Float = 0):Void {
		if (sHud == null || owner == null || path == null || path == "") return;
		try {
			var resolvedPath = resolvePhysicalPath(path);
			var container:DisplayObjectContainer = null;
			var targetX:Float = x;
			var targetY:Float = y;
			try {
				if (Std.isOfType(owner, DisplayObjectContainer)) {
					container = cast owner;
				} else if (Std.isOfType(owner, DisplayObject)) {
					var dispObj:DisplayObject = cast owner;
					container = dispObj.parent;
					targetX += dispObj.x;
					targetY += dispObj.y;
				} else if (Reflect.field(owner, "addChild") != null || Reflect.hasField(owner, "addChild")) {
					container = cast owner;
				}
			} catch (eC:Dynamic) {}
			if (container == null) return;

			var assets:AssetLoadingComponent = null;
			try { assets = cast Reflect.field(sHud, "mAssets"); } catch (eA:Dynamic) {}

			var texturesDict:Dynamic = Reflect.field(sHud, "mGlyphTextures");
			var pixelsDict:Dynamic = Reflect.field(sHud, "mGlyphPixels");
			var pathsDict:Dynamic = Reflect.field(sHud, "mGlyphPaths");
			var glyphsDict:Dynamic = Reflect.field(sHud, "mStarlingGlyphs");

			var placeImage = function(tex:Texture, bmd:Dynamic) {
				try {
					var curTextures:Dynamic = Reflect.field(sHud, "mGlyphTextures");
					if (curTextures == null) curTextures = texturesDict;
					var curPixels:Dynamic = Reflect.field(sHud, "mGlyphPixels");
					if (curPixels == null) curPixels = pixelsDict;
					var curPaths:Dynamic = Reflect.field(sHud, "mGlyphPaths");
					if (curPaths == null) curPaths = pathsDict;
					var curGlyphs:Dynamic = Reflect.field(sHud, "mStarlingGlyphs");
					if (curGlyphs == null) curGlyphs = glyphsDict;

					if (bmd != null && curPixels != null) {
						Dictionaries.set(curPixels, resolvedPath, bmd);
					}
					if (tex != null && curTextures != null) {
						Dictionaries.set(curTextures, resolvedPath, tex);
					}
					if (curPaths != null) {
						Dictionaries.set(curPaths, action, resolvedPath);
					}

					var oldImg:DisplayObject = null;
					try {
						oldImg = cast Dictionaries.get(curGlyphs, action);
					} catch (eO:Dynamic) {}
					if (oldImg != null) {
						oldImg.removeFromParent(true);
					}

					var newImg:Image = new Image(tex);
					newImg.touchable = false;
					newImg.x = targetX;
					newImg.y = targetY;
					newImg.width = size;
					newImg.height = height > 0 ? height : size;
					try {
						container.addChild(newImg);
					} catch (eAdd:Dynamic) {
						try {
							Reflect.callMethod(container, Reflect.field(container, "addChild"), [newImg]);
						} catch (eAdd2:Dynamic) {}
					}
					if (curGlyphs != null) {
						Dictionaries.set(curGlyphs, action, newImg);
					}
				} catch (eP:Dynamic) {}
			};

			// Check if texture is already cached for zero-delay synchronous rendering
			var cachedTex:Texture = null;
			try {
				if (texturesDict != null) cachedTex = cast Dictionaries.get(texturesDict, resolvedPath);
			} catch (eTex:Dynamic) {}
			if (cachedTex != null) {
				placeImage(cachedTex, null);
				return;
			}

			// Synchronous fast-path: load BitmapData directly from file via OpenFL (0ms latency)
			try {
				var bmd = openfl.display.BitmapData.fromFile(resolvedPath);
				if (bmd != null) {
					var tex = Texture.fromBitmapData(bmd);
					if (tex != null) {
						if (texturesDict != null) Dictionaries.set(texturesDict, resolvedPath, tex);
						placeImage(tex, bmd);
						return;
					}
				}
			} catch (eBmdSync:Dynamic) {}

			if (assets == null) return;
			assets.getImageAsset(resolvedPath, function(param1:ImageAsset) {
				try {
					var destroyed:Bool = Reflect.field(sHud, "mDestroyed") == true;
					if (destroyed) return;
					if (param1 == null || param1.image == null || param1.image.bitmapData == null) return;

					var curTextures:Dynamic = Reflect.field(sHud, "mGlyphTextures");
					if (curTextures == null) curTextures = texturesDict;
					var bmd:Dynamic = param1.image.bitmapData;
					var tex:Texture = null;
					try {
						tex = cast Dictionaries.get(curTextures, resolvedPath);
					} catch (eT:Dynamic) {}
					if (tex == null) {
						tex = Texture.fromBitmapData(bmd);
						if (tex != null && curTextures != null) Dictionaries.set(curTextures, resolvedPath, tex);
					}
					if (tex == null) return;
					placeImage(tex, bmd);
				} catch (eCb:Dynamic) {}
			});
		} catch (e:Dynamic) {}
	}

	function setStarlingTopRightGlyph(sHud:Dynamic, action:String, owner:Dynamic, path:String, gear:Bool):Void {
		if (sHud == null || owner == null || path == null || path == "") return;
		try {
			var resolved = resolvePhysicalPath(path);
			var sx:Float = 1.0;
			var sy:Float = 1.0;
			try {
				if (Std.isOfType(owner, DisplayObject)) {
					var d:DisplayObject = cast owner;
					sx = d.scaleX;
					sy = d.scaleY;
				} else {
					if (Reflect.field(owner, "scaleX") != null) sx = Reflect.field(owner, "scaleX");
					if (Reflect.field(owner, "scaleY") != null) sy = Reflect.field(owner, "scaleY");
				}
			} catch (eS:Dynamic) {}
			if (sx <= 0.001) sx = 1.0;
			if (sy <= 0.001) sy = 1.0;
			var pos:Dynamic = null;
			var sz:Dynamic = null;
			try {
				var htrCls:Dynamic = Type.resolveClass("uI.hud.HudTopRightLayout");
				if (htrCls != null) {
					pos = Reflect.callMethod(htrCls, Reflect.field(htrCls, "glyphPosition"), [gear, sx, sy]);
					sz = Reflect.callMethod(htrCls, Reflect.field(htrCls, "glyphSize"), [sx, sy]);
				}
			} catch (eHtr:Dynamic) {}
			var posX:Float = pos != null ? pos.x : (gear ? (36.05 - (39.477 / sx) / 2) : (15.15 - (39.477 / sx) / 2));
			var posY:Float = pos != null ? pos.y : (gear ? (-32.75 - (39.477 / sy) / 2) : (-13.35 - (39.477 / sy) / 2));
			var szW:Float = sz != null ? sz.x : (39.477 / sx);
			var szH:Float = sz != null ? sz.y : (39.477 / sy);
			setStarlingActionGlyph(sHud, action, owner, resolved, posX, posY, szW, szH);
		} catch (e:Dynamic) {}
	}

	static function isControllerGlyphPath(path:String):Bool {
		if (path == null || path == "") return false;
		if (path.indexOf("Keyboard & Mouse") != -1 || path.indexOf("_Key_") != -1) return false;
		return true;
	}

	function hasActiveControllerGlyphs(sHud:Dynamic):Bool {
		if (sHud == null) return false;
		try {
			var glyphPaths:Dynamic = Reflect.field(sHud, "mGlyphPaths");
			if (glyphPaths != null) {
				for (act in [
					"attack_weapon_1", "attack_weapon_2", "attack_weapon_3",
					"use_consumable_one", "use_consumable_two", "use_dungeon_buster",
					"toggle_menu", "toggle_chat_log"
				]) {
					var p:Dynamic = Dictionaries.get(glyphPaths, act);
					if (p != null) {
						var pathStr = Std.string(p);
						if (isControllerGlyphPath(pathStr)) return true;
					}
				}
			}
		} catch (e:Dynamic) {}
		return false;
	}

	function isAnyKeyboardLabelVisible(sHud:Dynamic):Bool {
		if (sHud == null) return false;
		try {
			var n1:Dynamic = sHud.node("consumables_01.label");
			if (n1 != null && n1.visible == true) return true;
			var n2:Dynamic = sHud.node("consumables_02.label");
			if (n2 != null && n2.visible == true) return true;
			var n3:Dynamic = sHud.node("UI_weapons.weapon_z.label");
			if (n3 != null && n3.visible == true) return true;
		} catch (e:Dynamic) {}
		return false;
	}

	function isAnyKeyboardLabelHidden(sHud:Dynamic):Bool {
		if (sHud == null) return false;
		try {
			var n1:Dynamic = sHud.node("consumables_01.label");
			if (n1 != null && n1.visible == false) return true;
			var n2:Dynamic = sHud.node("UI_weapons.weapon_z.label");
			if (n2 != null && n2.visible == false) return true;
		} catch (e:Dynamic) {}
		return false;
	}

	function removeActionGlyph(sHud:Dynamic, action:String):Void {
		if (sHud == null || action == null) return;
		try {
			var dict:Dynamic = Reflect.field(sHud, "mStarlingGlyphs");
			if (dict != null) {
				var img:Dynamic = Dictionaries.get(dict, action);
				if (img != null) {
					if (Reflect.field(img, "removeFromParent") != null) {
						Reflect.callMethod(img, Reflect.field(img, "removeFromParent"), [true]);
					}
					Dictionaries.remove(dict, action);
				}
			}
		} catch (e1:Dynamic) {}
		try {
			var pDict:Dynamic = Reflect.field(sHud, "mGlyphPaths");
			if (pDict != null) {
				Dictionaries.remove(pDict, action);
			}
		} catch (e2:Dynamic) {}
	}

	function removeCloseGlyph(sHud:Dynamic):Void {
		if (sHud == null) return;
		removeActionGlyph(sHud, "toggle_menu");
	}

	function removeBusterGlyph(sHud:Dynamic):Void {
		if (sHud == null) return;
		removeActionGlyph(sHud, "use_dungeon_buster");
		try {
			var busterNode:Dynamic = null;
			var view:Dynamic = Reflect.field(sHud, "mView");
			if (view != null && Reflect.field(view, "node") != null) {
				busterNode = Reflect.callMethod(view, Reflect.field(view, "node"), ["UI_buster_active.buster_activated"]);
			}
			if (busterNode == null && Reflect.field(sHud, "node") != null) {
				busterNode = Reflect.callMethod(sHud, Reflect.field(sHud, "node"), ["UI_buster_active.buster_activated"]);
			}
			if (busterNode != null && Std.isOfType(busterNode, DisplayObjectContainer)) {
				var doc:DisplayObjectContainer = cast busterNode;
				var i = doc.numChildren - 1;
				while (i >= 0) {
					var child = doc.getChildAt(i);
					if (Std.isOfType(child, starling.display.Image)) {
						child.removeFromParent(true);
					}
					i--;
				}
			}
		} catch (e:Dynamic) {}
	}

	function removeCombatGlyphs(sHud:Dynamic):Void {
		if (sHud == null) return;
		try {
			for (action in [
				"attack_weapon_1", "attack_weapon_2", "attack_weapon_3",
				"use_consumable_one", "use_consumable_two",
				"use_dungeon_buster", "toggle_menu", "revive_ally"
			]) {
				removeActionGlyph(sHud, action);
			}
			removeBusterGlyph(sHud);
		} catch (eComb:Dynamic) {}
	}

	function removeChatLogGlyph(sHud:Dynamic):Void {
		if (sHud == null) return;
		try {
			removeActionGlyph(sHud, "toggle_chat_log");
			removeActionGlyph(sHud, "open_chat_keyboard");

			// Flash chat clip
			var chatClip:Dynamic = Reflect.field(sHud, "mChatClip");
			if (chatClip != null) {
				var logBtn:Dynamic = Reflect.field(chatClip, "log_btn");
				if (logBtn != null) {
					try {
						Reflect.callMethod(sHud, Reflect.field(sHud, "removeControllerIcons"), [logBtn]);
					} catch (eRCI:Dynamic) {}
				}
			}
		} catch (eChat:Dynamic) {}
	}

	function removeTopRightGlyphs(sHud:Dynamic):Void {
		if (sHud == null) return;
		removeCloseGlyph(sHud);
		removeActionGlyph(sHud, "open_options_menu");
		try {
			var closeNode:Dynamic = getCloseNode(sHud);
			if (closeNode != null && Std.isOfType(closeNode, DisplayObjectContainer)) {
				var doc:DisplayObjectContainer = cast closeNode;
				var i = doc.numChildren - 1;
				while (i >= 0) {
					var child = doc.getChildAt(i);
					if (Std.isOfType(child, starling.display.Image)) {
						child.removeFromParent(true);
					}
					i--;
				}
			}
		} catch (e1:Dynamic) {}
		try {
			var optRoot:Dynamic = getOptionsViewRoot(sHud);
			if (optRoot != null && Std.isOfType(optRoot, DisplayObjectContainer)) {
				var doc:DisplayObjectContainer = cast optRoot;
				var i = doc.numChildren - 1;
				while (i >= 0) {
					var child = doc.getChildAt(i);
					if (Std.isOfType(child, starling.display.Image)) {
						child.removeFromParent(true);
					}
					i--;
				}
			}
		} catch (e2:Dynamic) {}
	}

	function updateBusterPrompt(sHud:Dynamic, hasGlyph:Bool):Void {
		if (sHud == null) return;
		try {
			var pressStr = "PRESS   ";
			var offset:Float = -5.0;
			if (!hasGlyph) {
				var busterKey = getActionDisplayName("useDungeonBuster");
				var prefix = "PRESS ";
				try {
					var locCls:Dynamic = Type.resolveClass("facade.Locale");
					if (locCls != null) {
						var s = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_KEYBOARD"]);
						if (s != null && s != "") prefix = s;
					}
				} catch (eL:Dynamic) {}
				pressStr = prefix + busterKey;
				offset = 0.0;
			} else {
				try {
					var locCls:Dynamic = Type.resolveClass("facade.Locale");
					if (locCls != null) {
						var s = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_CONTROLLER"]);
						if (s != null && s != "") pressStr = s;
					}
				} catch (eL:Dynamic) {}
			}
			var paths:Array<String> = [
				"UI_buster_active.buster_activated.up.db_pressbutton_text",
				"UI_buster_active.buster_activated.over.mc.db_pressbutton_text",
				"UI_buster_glow.buster_text.buster_text_label.db_pressbutton_text"
			];
			for (p in paths) {
				try {
					var nd:Dynamic = null;
					var view:Dynamic = Reflect.field(sHud, "mView");
					if (view != null && Reflect.field(view, "node") != null) {
						nd = Reflect.callMethod(view, Reflect.field(view, "node"), [p]);
					}
					if (nd == null && Reflect.field(sHud, "node") != null) {
						nd = Reflect.callMethod(sHud, Reflect.field(sHud, "node"), [p]);
					}
					if (nd != null && Reflect.field(nd, "setHudOffset") != null) {
						Reflect.callMethod(nd, Reflect.field(nd, "setHudOffset"), [offset, 0]);
					}
					sHud.text(p, pressStr, true);
				} catch (eP:Dynamic) {}
			}
		} catch (e:Dynamic) {}
	}

	function isKeyboardLabelVisible(sHud:Dynamic):Bool {
		if (sHud == null) return false;
		try {
			var node:Dynamic = sHud.node("UI_weapons.weapon_z.label");
			if (node != null && node.visible == true) return true;
		} catch (e:Dynamic) {}
		return false;
	}

	function isHudReady(hud:Dynamic):Bool {
		if (hud == null) return false;
		try {
			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;
				if (Reflect.field(sHud, "mDestroyed") == true) return false;
				var view:Dynamic = Reflect.field(sHud, "mView");
				if (view == null) return false;

				var isTown:Bool = false;
				try {
					if (facade != null && Reflect.field(facade, "isTown") != null) {
						isTown = Reflect.callMethod(facade, Reflect.field(facade, "isTown"), []);
					}
				} catch (eT:Dynamic) {}

				var weapons:Dynamic = Reflect.field(sHud, "mWeapons");
				if (isTown || (weapons != null && weapons.length == 0)) {
					// Town HUD is ready once view exists
					return true;
				}

				// In dungeon, require hero and weapons
				if (weapons == null || weapons.length < 3) return false;
				var hero:Dynamic = Reflect.field(sHud, "mHeroOwner");
				if (hero == null) return false;
				return true;
			} else if (hudName == "uI.hud.UIHud") {
				return true;
			}
		} catch (e:Dynamic) {}
		return false;
	}

	function enforceHUDState():Void {
		if (facade == null) return;
		try {
			var curState:Dynamic = facade.mainStateMachine != null ? facade.mainStateMachine.currentState : null;
			if (curState != lastStateMachineState) {
				lastStateMachineState = curState;
				lastEnforcedHud = null;
				lastEnforcedDevice = "";
			}

			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var state = getDesiredPromptState();
			var deviceKey = buttonsUsed + "_" + promptMode + "_" + controllerStyle + "_" + keyboardStyle + "_" + state;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;
				killStarlingGlyphTask(sHud);
				var view:Dynamic = Reflect.field(sHud, "mView");

				var needsSync:Bool = (hud != lastEnforcedHud || deviceKey != lastEnforcedDevice || view != lastEnforcedView);

				// Physical check: verify whether weapon prompts are still attached to the display list
				if (!needsSync && isHudReady(hud)) {
					if (state == "controller" || keyboardStyle != "text") {
						var sGlyphs:Dynamic = Reflect.field(sHud, "mStarlingGlyphs");
						var wImg:Dynamic = sGlyphs != null ? Dictionaries.get(sGlyphs, "attack_weapon_1") : null;
						var isAttached:Bool = false;
						if (wImg != null) {
							var pObj:Dynamic = Reflect.getProperty(wImg, "parent");
							if (pObj == null) pObj = Reflect.field(wImg, "mParent");
							if (pObj == null) pObj = Reflect.field(wImg, "parent");
							isAttached = (pObj != null);
						}
						if (isAttached) {
							var mImg:Dynamic = sGlyphs != null ? Dictionaries.get(sGlyphs, "toggle_menu") : null;
							if (mImg != null) {
								var pM:Dynamic = Reflect.getProperty(mImg, "parent");
								if (pM == null) pM = Reflect.field(mImg, "mParent");
								if (pM == null) pM = Reflect.field(mImg, "parent");
								if (pM == null) isAttached = false;
							} else {
								isAttached = false;
							}
						}
						if (!isAttached) {
							needsSync = true;
						}
					} else {
						// Text mode: ensure weapon label is visible
						var lblNode:Dynamic = sHud.node("UI_weapons.weapon_z.label");
						if (lblNode != null && Reflect.field(lblNode, "visible") == false) {
							needsSync = true;
						}
					}
				}

				if (needsSync) {
					if (!isHudReady(hud)) return;
					lastEnforcedHud = hud;
					lastEnforcedDevice = deviceKey;
					lastEnforcedView = view;
					lastSyncTimestamp = getTimestamp();
					syncHUD(true);
					return;
				}

				// Keep Buster prompt text in sync
				var busterHasGlyph = (state == "controller" || keyboardStyle != "text");
				updateBusterPrompt(sHud, busterHasGlyph);
			} else if (hudName == "uI.hud.UIHud") {
				if (hud != lastEnforcedHud || deviceKey != lastEnforcedDevice) {
					if (!isHudReady(hud)) return;
					lastEnforcedHud = hud;
					lastEnforcedDevice = deviceKey;
					lastSyncTimestamp = getTimestamp();
					syncHUD(true);
				}
			}
		} catch (e:Dynamic) {}
	}

	function toBindingAction(action:String):String {
		return switch (action) {
			case "attack_weapon_1", "attackWeapon1": "attackWeapon1";
			case "attack_weapon_2", "attackWeapon2": "attackWeapon2";
			case "attack_weapon_3", "attackWeapon3": "attackWeapon3";
			case "use_consumable_one", "useConsumable1": "useConsumable1";
			case "use_consumable_two", "useConsumable2": "useConsumable2";
			case "use_dungeon_buster", "useDungeonBuster": "useDungeonBuster";
			case "toggle_menu", "toggleMenu": "toggleMenu";
			case "open_options_menu", "openOptionsMenu": "openOptionsMenu";
			case "toggle_chat_log", "toggleChatLog": "toggleChatLog";
			case "open_chat_keyboard", "openChatKeyboard": "openChatKeyboard";
			case "revive_ally", "reviveAlly": "reviveAlly";
			default: action;
		};
	}

	function getActionKeyCode(action:String):Int {
		if (facade == null) return 0;
		var bindAction = toBindingAction(action);
		var kb:Dynamic = Reflect.field(facade, "keyBindings");
		if (kb == null) kb = Reflect.field(facade, "mKeyBindings");
		var code:Int = 0;
		if (kb != null) {
			try {
				if (buttonsUsed == "alt") {
					code = Reflect.callMethod(kb, Reflect.field(kb, "getAlternate"), [bindAction]);
					if (code == 0) code = Reflect.callMethod(kb, Reflect.field(kb, "getPrimary"), [bindAction]);
				} else {
					code = Reflect.callMethod(kb, Reflect.field(kb, "getPrimary"), [bindAction]);
					if (code == 0) code = Reflect.callMethod(kb, Reflect.field(kb, "getAlternate"), [bindAction]);
				}
			} catch (e:Dynamic) {}
		}
		if (code == 0) {
			code = switch (bindAction) {
				case "attackWeapon1": 90; // Z
				case "attackWeapon2": 88; // X
				case "attackWeapon3": 67; // C
				case "useConsumable1": 49; // 1
				case "useConsumable2": 50; // 2
				case "useDungeonBuster": 66; // B
				case "toggleMenu": 27; // Esc
				case "openOptionsMenu": 79; // O
				default: 0;
			};
		}
		return code;
	}

	function getActionDisplayName(action:String):String {
		var code = getActionKeyCode(action);
		try {
			var kn:Dynamic = Type.resolveClass("input.keyBindings.KeyNames");
			if (kn != null) {
				return Reflect.callMethod(kn, Reflect.field(kn, "displayName"), [code]);
			}
		} catch (e:Dynamic) {}
		if (code >= 65 && code <= 90) return String.fromCharCode(code);
		if (code >= 48 && code <= 57) return String.fromCharCode(code);
		return switch (code) {
			case 32: "SPACE";
			case 27: "ESC";
			case 13: "ENTER";
			default: "KEY " + code;
		};
	}

	function updateKeyboardLabels(sHud:Dynamic):Void {
		if (sHud == null || facade == null) return;
		try {
			var w1 = getActionDisplayName("attackWeapon1");
			var w2 = getActionDisplayName("attackWeapon2");
			var w3 = getActionDisplayName("attackWeapon3");
			var c1 = getActionDisplayName("useConsumable1");
			var c2 = getActionDisplayName("useConsumable2");

			sHud.text("UI_weapons.weapon_z.label", w1, true);
			sHud.text("UI_weapons.weapon_x.label", w2, true);
			sHud.text("UI_weapons.weapon_c.label", w3, true);
			sHud.text("consumables_01.label", c1, true);
			sHud.text("consumables_02.label", c2, true);

			var busterKey = getActionDisplayName("useDungeonBuster");
			var pressStr = "Press ";
			try {
				var locCls:Dynamic = Type.resolveClass("facade.Locale");
				if (locCls != null) {
					pressStr = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_KEYBOARD"]);
				}
			} catch (eLoc:Dynamic) {}
			var busterStr = pressStr + busterKey;
			var paths:Array<String> = [
				"UI_buster_active.buster_activated.up.db_pressbutton_text",
				"UI_buster_active.buster_activated.over.mc.db_pressbutton_text",
				"UI_buster_glow.buster_text.buster_text_label.db_pressbutton_text"
			];
			for (p in paths) {
				sHud.text(p, busterStr, true);
				var nd:Dynamic = sHud.node(p);
				if (nd != null && Reflect.field(nd, "setHudOffset") != null) {
					Reflect.callMethod(nd, Reflect.field(nd, "setHudOffset"), [0, 0]);
				}
			}
		} catch (e:Dynamic) {}
	}

	function applyKBMPrompts():Void {
		if (facade == null) return;
		try {
			freezeSteamInputOrigins();

			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;
				detachStarlingListeners(sHud);

				var sim:Dynamic = Reflect.field(facade, "steamInputManager");
				if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
				var glyphMap:Dynamic = sim != null ? Reflect.field(sim, "mInputActionNameToControllerGlyphFilePath") : null;
				var pathsDict:Dynamic = getLocalGlyphPathsDict();

				// In Text mode, clean weapon and consumable glyphs so native text labels show
				if (glyphMap != null) {
					Dictionaries.set(glyphMap, "attack_weapon_1", "");
					Dictionaries.set(glyphMap, "attack_weapon_2", "");
					Dictionaries.set(glyphMap, "attack_weapon_3", "");
					Dictionaries.set(glyphMap, "use_consumable_one", "");
					Dictionaries.set(glyphMap, "use_consumable_two", "");
					Dictionaries.set(glyphMap, "use_dungeon_buster", "");
					Dictionaries.set(glyphMap, "toggle_chat_log", "");
					Dictionaries.set(glyphMap, "open_chat_keyboard", "");
					Dictionaries.set(glyphMap, "revive_ally", "");
					Dictionaries.set(glyphMap, "toggle_menu", "");
					Dictionaries.set(glyphMap, "open_options_menu", "");
				}

				// Clean any active combat glyph images, top right glyphs (ESC & O), and controller chat log icon
				removeCombatGlyphs(sHud);
				removeTopRightGlyphs(sHud);
				removeChatLogGlyph(sHud);

				// Make native keyboard labels visible
				sHud.visible("consumables_01.label", true);
				sHud.visible("consumables_02.label", true);
				sHud.visible("UI_weapons.weapon_z.label", true);
				sHud.visible("UI_weapons.weapon_x.label", true);
				sHud.visible("UI_weapons.weapon_c.label", true);
				sHud.refreshKeyboardLabels();
				updateKeyboardLabels(sHud);
				updateBusterPrompt(sHud, false);

				// Buster in text mode shows "PRESS B" text
				try {
					Reflect.callMethod(sHud, Reflect.field(sHud, "syncBusterPrompt"), []);
				} catch (eB:Dynamic) {}

				var chat:Dynamic = Reflect.field(sHud, "mChat");
				if (chat != null) {
					try { Reflect.callMethod(chat, Reflect.field(chat, "setChatPromptVisible"), [true]); } catch (eC:Dynamic) {}
				}
			} else if (hudName == "uI.hud.UIHud") {
				var uHud:Dynamic = hud;
				var hudIcons:Dynamic = Reflect.field(uHud, "mHudControllerIcons");
				if (hudIcons != null) {
					Reflect.callMethod(uHud, Reflect.field(uHud, "hideControllerIcons"), [hudIcons]);
				}
				var extIcons:Dynamic = Reflect.field(uHud, "mExternalControllerIcons");
				if (extIcons != null) {
					Reflect.callMethod(uHud, Reflect.field(uHud, "hideControllerIcons"), [extIcons]);
				}
				uHud.setAllKeyboardIconsVisibility(true);
				uHud.refreshKeyboardLabels();
				uHud.setBusterPressText(true);
			}
		} catch (e:Dynamic) {}
	}

	function applyKeyboardGlyphPrompts(style:String):Void {
		if (facade == null) return;
		try {
			freezeSteamInputOrigins();

			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;
				detachStarlingListeners(sHud);

				var sim:Dynamic = Reflect.field(facade, "steamInputManager");
				if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
				var glyphMap:Dynamic = sim != null ? Reflect.field(sim, "mInputActionNameToControllerGlyphFilePath") : null;
				var pathsDict:Dynamic = getLocalGlyphPathsDict();

				var isDark = (style != "kbm_light");
				var escCode = getActionKeyCode("toggleMenu");
				var escCand = getCandidateForKeyCode(escCode, isDark);
				var escP:String = (escCand != null && escCand != "") ? findGlyphPath(pathsDict, [escCand]) : null;
				if (escP == null || escP == "") {
					escP = findGlyphPath(pathsDict, [isDark ? "Esc_Key_Dark" : "Esc_Key_Light"]);
				}
				if (escP == null || escP == "") {
					escP = resolvePhysicalPath(isDark ? "Resources/Glyphs/Keyboard & Mouse/Dark/Esc_Key_Dark.png"
					                                  : "Resources/Glyphs/Keyboard & Mouse/Light/Esc_Key_Light.png");
				}

				var optCode = getActionKeyCode("openOptionsMenu");
				var optCand = getCandidateForKeyCode(optCode, isDark);
				var optP:String = (optCand != null && optCand != "") ? findGlyphPath(pathsDict, [optCand]) : null;
				if (optP == null || optP == "") {
					optP = findGlyphPath(pathsDict, [isDark ? "O_Key_Dark" : "O_Key_Light"]);
				}
				if (optP == null || optP == "") {
					optP = resolvePhysicalPath(isDark ? "Resources/Glyphs/Keyboard & Mouse/Dark/O_Key_Dark.png"
					                                  : "Resources/Glyphs/Keyboard & Mouse/Light/O_Key_Light.png");
				}
				var busterCode = getActionKeyCode("useDungeonBuster");
				var busterCand = getCandidateForKeyCode(busterCode, isDark);
				var busterP:String = (busterCand != null && busterCand != "") ? findGlyphPath(pathsDict, [busterCand]) : null;
				if (busterP == null || busterP == "") {
					busterP = findGlyphPath(pathsDict, [isDark ? "B_Key_Dark" : "B_Key_Light"]);
				}

				// 1. Resolve and set glyph paths for all keyboard actions
				var mapActions = [
					"attack_weapon_1" => "attackWeapon1",
					"attack_weapon_2" => "attackWeapon2",
					"attack_weapon_3" => "attackWeapon3",
					"use_consumable_one" => "useConsumable1",
					"use_consumable_two" => "useConsumable2",
					"use_dungeon_buster" => "useDungeonBuster"
				];

				var resolvedPaths = new Map<String, String>();

				if (glyphMap != null) {
					for (act in mapActions.keys()) {
						var bindAct = mapActions.get(act);
						var code = getActionKeyCode(bindAct);
						var cand = getCandidateForKeyCode(code, isDark);
						var p = (cand != null && cand != "") ? findGlyphPath(pathsDict, [cand]) : null;
						if (p == null || p == "") {
							p = switch (act) {
								case "use_dungeon_buster": busterP;
								case "attack_weapon_1": findGlyphPath(pathsDict, [isDark ? "Z_Key_Dark" : "Z_Key_Light", isDark ? "J_Key_Dark" : "J_Key_Light"]);
								case "attack_weapon_2": findGlyphPath(pathsDict, [isDark ? "X_Key_Dark" : "X_Key_Light", isDark ? "K_Key_Dark" : "K_Key_Light"]);
								case "attack_weapon_3": findGlyphPath(pathsDict, [isDark ? "C_Key_Dark" : "C_Key_Light", isDark ? "L_Key_Dark" : "L_Key_Light"]);
								case "use_consumable_one": findGlyphPath(pathsDict, [isDark ? "1_Key_Dark" : "1_Key_Light"]);
								case "use_consumable_two": findGlyphPath(pathsDict, [isDark ? "2_Key_Dark" : "2_Key_Light"]);
								default: "";
							};
						}
						resolvedPaths.set(act, (p != null ? p : ""));
						Dictionaries.set(glyphMap, act, (p != null ? p : ""));
					}

					Dictionaries.set(glyphMap, "toggle_chat_log", "");
					Dictionaries.set(glyphMap, "open_chat_keyboard", "");
					Dictionaries.set(glyphMap, "revive_ally", "");
					Dictionaries.set(glyphMap, "toggle_menu", (escP != null ? escP : ""));
					Dictionaries.set(glyphMap, "open_options_menu", (optP != null ? optP : ""));
				}

				// Restore Locale so PRESS string displays on Buster
				restoreLocaleBusterString();

				// Hide text labels since we are placing glyphs
				sHud.visible("UI_weapons.weapon_z.label", false);
				sHud.visible("UI_weapons.weapon_x.label", false);
				sHud.visible("UI_weapons.weapon_c.label", false);
				sHud.visible("consumables_01.label", false);
				sHud.visible("consumables_02.label", false);

				// Directly inject weapon glyphs into weapon slots
				var weapons:Dynamic = Reflect.field(sHud, "mWeapons");
				if (weapons != null) {
					var wActs = ["attack_weapon_1", "attack_weapon_2", "attack_weapon_3"];
					for (i in 0...3) {
						if (i < weapons.length && weapons[i] != null && weapons[i].button != null && weapons[i].button.root != null) {
							var actName = wActs[i];
							var p = resolvedPaths.get(actName);
							if (p != null && p != "") {
								setStarlingActionGlyph(sHud, actName, weapons[i].button.root, p, 13, -50);
							}
						}
					}
				}

				// Directly inject consumable glyphs into consumable slots
				var consumables:Dynamic = Reflect.field(sHud, "mConsumables");
				if (consumables != null) {
					var cActs = ["use_consumable_one", "use_consumable_two"];
					for (i in 0...2) {
						if (i < consumables.length && consumables[i] != null && consumables[i].button != null && consumables[i].button.root != null) {
							var actName = cActs[i];
							var p = resolvedPaths.get(actName);
							if (p != null && p != "") {
								setStarlingActionGlyph(sHud, actName, consumables[i].button.root, p, 13, -50);
							}
						}
					}
				}

				// Clean controller chat log icon
				removeChatLogGlyph(sHud);

				// Top right ESC on Close 'X' and O on Gear
				if (escP != null && escP != "") {
					var closeNode:Dynamic = getCloseNode(sHud);
					if (closeNode != null) {
						setStarlingTopRightGlyph(sHud, "toggle_menu", closeNode, escP, false);
					}
				}
				if (optP != null && optP != "") {
					var optRoot:Dynamic = getOptionsViewRoot(sHud);
					if (optRoot != null) {
						setStarlingTopRightGlyph(sHud, "open_options_menu", optRoot, optP, true);
					}
				}

				// Directly place Buster glyph
				if (busterP != null && busterP != "") {
					var busterNode:Dynamic = sHud.node("UI_buster_active.buster_activated");
					if (busterNode != null) {
						setStarlingActionGlyph(sHud, "use_dungeon_buster", busterNode, busterP, 8, -8);
					}
				}

				// Ensure Buster displays "PRESS   " with glyph
				updateBusterPrompt(sHud, true);

				// Keep chat prompt visible for keyboard
				var chat:Dynamic = Reflect.field(sHud, "mChat");
				if (chat != null) {
					try { Reflect.callMethod(chat, Reflect.field(chat, "setChatPromptVisible"), [true]); } catch (eC:Dynamic) {}
				}
			} else if (hudName == "uI.hud.UIHud") {
				var uHud:Dynamic = hud;
				uHud.initAllControllerIcons();
				var extIcons:Dynamic = Reflect.field(uHud, "mExternalControllerIcons");
				if (extIcons != null) {
					Reflect.callMethod(uHud, Reflect.field(uHud, "refreshControllerIcons"), [extIcons]);
				}
				uHud.setAllKeyboardIconsVisibility(false);
			}
		} catch (e:Dynamic) {}
	}

	function applyControllerPrompts():Void {
		if (facade == null) return;
		try {
			applyGlyphPreference();

			var pref = toPreferenceStyleName(controllerStyle);
			ensureFallbackGlyphs(pref);
			freezeSteamInputOrigins();

			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;
				detachStarlingListeners(sHud);

				var sim:Dynamic = Reflect.field(facade, "steamInputManager");
				if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");

				// Restore Locale so PRESS string displays on Buster
				restoreLocaleBusterString();

				// Hide native keyboard text labels
				sHud.visible("UI_weapons.weapon_z.label", false);
				sHud.visible("UI_weapons.weapon_x.label", false);
				sHud.visible("UI_weapons.weapon_c.label", false);
				sHud.visible("consumables_01.label", false);
				sHud.visible("consumables_02.label", false);

				// Place controller glyphs on weapons, consumables, close, options, and buster
				var glyphMap:Dynamic = sim != null ? Reflect.field(sim, "mInputActionNameToControllerGlyphFilePath") : null;
				if (glyphMap != null) {
					var effPref = (pref == null || pref == "" || pref == "auto") ? "Xbox 360" : pref;
					var pathsDict:Dynamic = getLocalGlyphPathsDict();

					var menuP:String = Std.string(Dictionaries.get(glyphMap, "toggle_menu"));
					if (menuP == null || menuP == "" || menuP == "null" || menuP == "undefined") {
						menuP = findGlyphPath(pathsDict, getCandidates(effPref, "Menu"));
						if (menuP == null || menuP == "") menuP = getFallbackControllerPath(effPref, "Menu");
					}
					var viewP:String = Std.string(Dictionaries.get(glyphMap, "open_options_menu"));
					if (viewP == null || viewP == "" || viewP == "null" || viewP == "undefined") {
						viewP = findGlyphPath(pathsDict, getCandidates(effPref, "View"));
						if (viewP == null || viewP == "") viewP = getFallbackControllerPath(effPref, "View");
					}
					var logP:String = Std.string(Dictionaries.get(glyphMap, "toggle_chat_log"));
					if (logP == null || logP == "" || logP == "null" || logP == "undefined") {
						logP = findGlyphPath(pathsDict, getCandidates(effPref, "Dpad_Left"));
						if (logP == null || logP == "") logP = getFallbackControllerPath(effPref, "Dpad_Left");
					}
					var busterP:String = Std.string(Dictionaries.get(glyphMap, "use_dungeon_buster"));
					if (busterP == null || busterP == "" || busterP == "null" || busterP == "undefined") {
						busterP = findGlyphPath(pathsDict, getCandidates(effPref, "Y"));
						if (busterP == null || busterP == "") busterP = getFallbackControllerPath(effPref, "Y");
					}

					if (menuP != null && menuP != "" && menuP != "null") {
						var closeNode:Dynamic = getCloseNode(sHud);
						if (closeNode != null) {
							setStarlingTopRightGlyph(sHud, "toggle_menu", closeNode, menuP, false);
						}
					}
					if (viewP != null && viewP != "" && viewP != "null") {
						var optRoot:Dynamic = getOptionsViewRoot(sHud);
						if (optRoot != null) {
							setStarlingTopRightGlyph(sHud, "open_options_menu", optRoot, viewP, true);
						}
					}
					if (logP != null && logP != "" && logP != "null") {
						var logRoot:Dynamic = getChatLogRoot(sHud);
						if (logRoot != null) {
							setStarlingActionGlyph(sHud, "toggle_chat_log", logRoot, logP, 25, -10, 20);
						} else {
							var chatClip:Dynamic = Reflect.field(sHud, "mChatClip");
							if (chatClip != null && chatClip.log_btn != null) {
								try {
									Reflect.callMethod(sHud, Reflect.field(sHud, "initControllerIcon"), [
										"toggle_chat_log",
										chatClip.log_btn,
										new flash.geom.Vector3D(25, -10),
										new flash.geom.Point(20, 20)
									]);
								} catch (eFCI:Dynamic) {}
							}
						}
					}

					var weapons:Dynamic = Reflect.field(sHud, "mWeapons");
					if (weapons != null) {
						var wActs = ["attack_weapon_1", "attack_weapon_2", "attack_weapon_3"];
						var wBtns = ["A", "X", "B"];
						for (i in 0...3) {
							if (i < weapons.length && weapons[i] != null && weapons[i].button != null && weapons[i].button.root != null) {
								var p:String = Std.string(Dictionaries.get(glyphMap, wActs[i]));
								if (p == null || p == "" || p == "null" || p == "undefined") {
									p = findGlyphPath(pathsDict, getCandidates(effPref, wBtns[i]));
									if (p == null || p == "") p = getFallbackControllerPath(effPref, wBtns[i]);
								}
								if (p != null && p != "" && p != "null") {
									setStarlingActionGlyph(sHud, wActs[i], weapons[i].button.root, p, 13, -50);
								}
							}
						}
					}

					var consumables:Dynamic = Reflect.field(sHud, "mConsumables");
					if (consumables != null) {
						var cActs = ["use_consumable_one", "use_consumable_two"];
						var cBtns = ["LB", "RB"];
						for (i in 0...2) {
							if (i < consumables.length && consumables[i] != null && consumables[i].button != null && consumables[i].button.root != null) {
								var p:String = Std.string(Dictionaries.get(glyphMap, cActs[i]));
								if (p == null || p == "" || p == "null" || p == "undefined") {
									p = findGlyphPath(pathsDict, getCandidates(effPref, cBtns[i]));
									if (p == null || p == "") p = getFallbackControllerPath(effPref, cBtns[i]);
								}
								if (p != null && p != "" && p != "null") {
									setStarlingActionGlyph(sHud, cActs[i], consumables[i].button.root, p, 13, -50);
								}
							}
						}
					}

					if (busterP != null && busterP != "" && busterP != "null") {
						var busterNode:Dynamic = sHud.node("UI_buster_active.buster_activated");
						if (busterNode != null) {
							setStarlingActionGlyph(sHud, "use_dungeon_buster", busterNode, busterP, 8, -8);
						}
					}
				}

				// Ensure Buster displays "PRESS   " with glyph
				updateBusterPrompt(sHud, true);
			} else if (hudName == "uI.hud.UIHud") {
				var uHud:Dynamic = hud;
				uHud.initAllControllerIcons();
				var extIcons:Dynamic = Reflect.field(uHud, "mExternalControllerIcons");
				if (extIcons != null) {
					Reflect.callMethod(uHud, Reflect.field(uHud, "refreshControllerIcons"), [extIcons]);
				}
				uHud.setAllKeyboardIconsVisibility(false);
			}
		} catch (e:Dynamic) {}
	}

	function applyGlyphPreference():Void {
		if (facade == null) return;
		var dbcmCheck:Dynamic = Reflect.field(facade, "dbConfigManager");
		if (dbcmCheck == null) dbcmCheck = Reflect.field(facade, "mDBConfigManager");
		if (dbcmCheck == null) return;

		var prefValue = (controllerStyle == "auto") ? "" : toPreferenceStyleName(controllerStyle);

		var dbcm:Dynamic = Reflect.field(facade, "dbConfigManager");
		if (dbcm == null) dbcm = Reflect.field(facade, "mDBConfigManager");
		if (dbcm != null) {
			var dicts:Array<Dynamic> = Reflect.field(dbcm, "mJsonDictionaries");
			if (dicts != null) {
				if (dicts.length == 0) dicts.push({});
				var top = dicts[dicts.length - 1];
				if (prefValue == "") {
					Reflect.deleteField(top, "ControllerGlyphPreference");
				} else {
					Reflect.setField(top, "ControllerGlyphPreference", prefValue);
				}
			}
		}

		var sim:Dynamic = Reflect.field(facade, "steamInputManager");
		if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
		if (sim != null) {
			ensureCustomLocalGlyphs();
			var state = getDesiredPromptState();
			if (state == "kbm") {
				ensureFallbackGlyphs("");
			} else {
				var eff = (prefValue != null && prefValue != "") ? prefValue : "Xbox 360";
				ensureFallbackGlyphs(eff);
			}
		}
	}

	function cleanNorm(s:String):String {
		return normKey(s);
	}

	function getCandidates(pref:String, ctrl:String):Array<String> {
		return getStyleCandidates(pref, ctrl);
	}

	function findGlyphPath(pathsDict:Dynamic, candidates:Array<String>):Null<String> {
		if (pathsDict == null || candidates == null) return null;
		for (name in candidates) {
			if (name == null || name == "") continue;
			var norm = cleanNorm(name);
			try {
				var p:Dynamic = Dictionaries.get(pathsDict, norm);
				if (p != null) {
					var s = Std.string(p);
					if (s != "" && s != "undefined" && s != "null") return s;
				}
			} catch (e:Dynamic) {}
		}
		return null;
	}

	function getSpecialCandidates(mode:String, action:String):Array<String> {
		var list:Array<String> = [];
		if (action == "toggle_chat_log" || action == "open_chat_keyboard") {
			return list;
		}
		switch (mode) {
			case "kbm_dark", "kbm_light":
				var isDark = mode == "kbm_dark";
				var code = getActionKeyCode(action);
				if (code > 0) {
					var cand = getCandidateForKeyCode(code, isDark);
					if (cand != null && cand != "") {
						list.push(cand);
					}
				}
		}
		return list;
	}

	function ensureFallbackGlyphs(pref:String):Void {
		var sim:Dynamic = Reflect.field(facade, "steamInputManager");
		if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
		if (sim == null) return;

		try {
			var pathsDict:Dynamic = getLocalGlyphPathsDict();

			var glyphMap:Dynamic = Reflect.field(sim, "mInputActionNameToControllerGlyphFilePath");
			if (glyphMap == null) return;

			var map = [
				"attack_weapon_1" => "A",
				"attack_weapon_2" => "X",
				"attack_weapon_3" => "B",
				"use_consumable_one" => "LB",
				"use_consumable_two" => "RB",
				"use_dungeon_buster" => "Y",
				"toggle_menu" => "Menu",
				"open_options_menu" => "View",
				"toggle_chat_log" => "Dpad_Left",
				"open_chat_keyboard" => "Dpad_Down",
				"revive_ally" => "Y"
			];

			var state = getDesiredPromptState();

			if (state == "kbm") {
				var isDark = (keyboardStyle != "kbm_light");
				var escP = findGlyphPath(pathsDict, [isDark ? "Esc_Key_Dark" : "Esc_Key_Light"]);
				var optP = findGlyphPath(pathsDict, [isDark ? "O_Key_Dark" : "O_Key_Light"]);
				if (escP != null && escP != "") Dictionaries.set(glyphMap, "toggle_menu", escP);
				if (optP != null && optP != "") Dictionaries.set(glyphMap, "open_options_menu", optP);
				return;
			}

			// Controller mode: clean up any stale keyboard keycap that might have been assigned to toggle_chat_log
			var curLog:Dynamic = Dictionaries.get(glyphMap, "toggle_chat_log");
			if (curLog != null && (Std.string(curLog).indexOf("Key_") != -1 || Std.string(curLog).indexOf("Space") != -1)) {
				Dictionaries.set(glyphMap, "toggle_chat_log", "");
			}

			var effectivePref = (pref == null || pref == "" || pref == "auto") ? "Xbox 360" : pref;

			// If controller is connected and style is "auto", update native Steamworks origins first
			var hasController = isAnyControllerConnected();
			if (controllerStyle == "auto" && hasController) {
				try {
					Reflect.callMethod(sim, Reflect.field(sim, "updateActionOrigins"), []);
				} catch (eU:Dynamic) {}
			}

			// Custom style candidates from bundled assets (or fallback when no controller connected)
			for (action in map.keys()) {
				var curP:Dynamic = Dictionaries.get(glyphMap, action);
				if (curP != null && curP != "" && curP != "error1" && controllerStyle == "auto" && hasController) {
					// Steamworks mapped this action natively; keep it!
					continue;
				}
				var ctrl = map[action];
				var candidates = getCandidates(effectivePref, ctrl);
				var filePath = findGlyphPath(pathsDict, candidates);
				if (filePath == null || filePath == "") {
					filePath = getFallbackControllerPath(effectivePref, ctrl);
				}
				Dictionaries.set(glyphMap, action, (filePath != null ? filePath : ""));
			}
		} catch (eFall:Dynamic) {}
	}

	function getCustomSettingsBridge():Dynamic {
		try {
			if (facade != null) {
				var bF:Dynamic = Reflect.field(facade, "customSettingsApi");
				if (bF != null && Reflect.field(bF, "invoke") != null) return bF;
			}

			var openflStage:Dynamic = (context != null && context.overlay != null && context.overlay.stage != null)
				? context.overlay.stage
				: (facade != null ? Reflect.field(facade, "stageRef") : null);
			if (openflStage != null) {
				try {
					var holder:Dynamic = Reflect.callMethod(openflStage, Reflect.field(openflStage, "getChildByName"), ["__customSettingsApiBridgeHolder__"]);
					if (holder != null) {
						var bH:Dynamic = Reflect.field(holder, "bridge");
						if (bH != null && Reflect.field(bH, "invoke") != null) return bH;
					}
				} catch (eHolder:Dynamic) {}
				var bS:Dynamic = Reflect.field(openflStage, "customSettingsApiBridge");
				if (bS != null && Reflect.field(bS, "invoke") != null) return bS;
			}

			if (context != null && context.overlay != null) {
				var bO:Dynamic = Reflect.field(context.overlay, "customSettingsApiBridge");
				if (bO != null && Reflect.field(bO, "invoke") != null) return bO;
			}

			var cls:Dynamic = Type.resolveClass("mods.custom_settings_api.CustomSettingsApi");
			if (cls != null) {
				var bC:Dynamic = Reflect.field(cls, "bridge");
				if (bC != null && Reflect.field(bC, "invoke") != null) return bC;
				try {
					var fn = Reflect.field(cls, "getBridge");
					if (fn != null) {
						var res = Reflect.callMethod(cls, fn, []);
						if (res != null && Reflect.field(res, "invoke") != null) return res;
					}
				} catch (eG:Dynamic) {}
			}
		} catch (e:Dynamic) {}
		return null;
	}

	function invokeBridge(bridge:Dynamic, method:String, args:Array<Dynamic>):Dynamic {
		if (bridge == null) return null;
		try {
			var invFn:Dynamic = Reflect.field(bridge, "invoke");
			if (invFn != null) {
				return Reflect.callMethod(bridge, invFn, [method, args]);
			}
			var fn:Dynamic = Reflect.field(bridge, method);
			if (fn != null) {
				return Reflect.callMethod(bridge, fn, args);
			}
		} catch (e:Dynamic) {
			if (context != null) context.log("invokeBridge error on " + method + ": " + Std.string(e));
		}
		return null;
	}

	function tryRegisterSettings():Bool {
		if (customSettingsRegistered) return true;

		var bridge:Dynamic = getCustomSettingsBridge();
		if (bridge == null) return false;

		try {
			var okCat = invokeBridge(bridge, "addCategory", ["input_hud", "INPUT HUD", "hud_input_selector"]);
			if (okCat != true) {
				return false;
			}

			invokeBridge(bridge, "addSimpleChoice", [
				"input_hud",
				"hud_buttons_used",
				"BUTTONS USED",
				"Selects which key binding from game controls to display on the HUD: Default (primary) or Alt (secondary).",
				["default", "alt"],
				["Default", "Alt"],
				buttonsUsed,
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != buttonsUsed) {
						buttonsUsed = s;
						if (nativeButtonsChoice != null) {
							try { nativeButtonsChoice.value = s; } catch (e:Dynamic) {}
						}
						syncHUD(true);
					}
				}
			]);

			invokeBridge(bridge, "addSimpleChoice", [
				"input_hud",
				"hud_prompt_mode",
				"BUTTON PROMPTS",
				"HUD prompt style: Auto Detect (switches dynamically between controller and keyboard), Keyboard, or Controller.",
				["auto", "kbm", "controller"],
				["Auto Detect", "Keyboard", "Controller"],
				promptMode,
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != promptMode) {
						promptMode = s;
						if (nativePromptChoice != null) {
							try { nativePromptChoice.value = s; } catch (e:Dynamic) {}
						}
						applyGlyphPreference();
						syncHUD(true);
					}
				}
			]);

			invokeBridge(bridge, "addSimpleChoice", [
				"input_hud",
				"hud_controller_style",
				"CONTROLLER STYLE",
				"Icon style used when controller prompts are displayed on the HUD (DualSense, Xbox, Nintendo Switch, etc.).",
				[
					"auto",
					"ps5",
					"ps4",
					"xbox",
					"xbox360",
					"switch",
					"steamdeck",
					"ps3",
					"xboxone",
					"steam",
					"wiiu",
					"wii",
					"psvita",
					"psmove",
					"googlestadia",
					"amazonluna",
					"ouya"
				],
				[
					"Auto Detect",
					"DualSense",
					"DualShock 4",
					"Xbox Series/One",
					"Xbox 360",
					"Nintendo Switch",
					"Steam Deck",
					"DualShock 3",
					"Xbox One",
					"Steam Controller",
					"Wii U",
					"Wii",
					"PS Vita",
					"PS Move",
					"Google Stadia",
					"Amazon Luna",
					"Ouya"
				],
				controllerStyle,
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != controllerStyle) {
						controllerStyle = s;
						if (nativeControllerStyleChoice != null) {
							try { nativeControllerStyleChoice.value = s; } catch (e:Dynamic) {}
						}
						applyGlyphPreference();
						syncHUD(true);
					}
				}
			]);

			invokeBridge(bridge, "addSimpleChoice", [
				"input_hud",
				"hud_keyboard_style",
				"KEYBOARD STYLE",
				"Visual style used when keyboard prompts are active: Text (labels), Dark Keys, or Light Keys.",
				["text", "kbm_dark", "kbm_light"],
				["Text", "Dark Keys", "Light Keys"],
				keyboardStyle,
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != keyboardStyle) {
						keyboardStyle = s;
						if (nativeKeyboardStyleChoice != null) {
							try { nativeKeyboardStyleChoice.value = s; } catch (e:Dynamic) {}
						}
						applyGlyphPreference();
						syncHUD(true);
					}
				}
			]);

			// Synchronize active values from CustomSettingsApi if persisted on disk
			var bVal:Dynamic = invokeBridge(bridge, "get", ["hud_buttons_used"]);
			if (bVal != null && Std.string(bVal) != "") buttonsUsed = Std.string(bVal);
			var pVal:Dynamic = invokeBridge(bridge, "get", ["hud_prompt_mode"]);
			if (pVal != null && Std.string(pVal) != "") promptMode = Std.string(pVal);
			var cVal:Dynamic = invokeBridge(bridge, "get", ["hud_controller_style"]);
			if (cVal != null && Std.string(cVal) != "") controllerStyle = Std.string(cVal);
			var kVal:Dynamic = invokeBridge(bridge, "get", ["hud_keyboard_style"]);
			if (kVal != null && Std.string(kVal) != "") keyboardStyle = Std.string(kVal);

			customSettingsRegistered = true;
			if (context != null) {
				context.log("HUD Input Selector registered settings via CustomSettingsApi bridge.");
			}
			applyGlyphPreference();
			syncHUD(true);
			return true;
		} catch (e:Dynamic) {
			if (context != null) context.log("Error registering via CustomSettingsApi bridge: " + Std.string(e));
			return false;
		}
	}

	function tryRegisterNativeApiSettings():Bool {
		if (context == null || nativeSettingsRegistered) return false;
		var settingsObj:Dynamic = context.settings;
		if (settingsObj == null) return false;

		try {
			nativeButtonsChoice = settingsObj.choice(
				"hud_buttons_used",
				"Buttons Used",
				"Selects which key binding from game controls to display on the HUD: Default (primary) or Alt (secondary).",
				[
					{value: "default", label: "Default"},
					{value: "alt", label: "Alt"}
				],
				buttonsUsed
			);
			if (nativeButtonsChoice != null && nativeButtonsChoice.value != null && nativeButtonsChoice.value != "") buttonsUsed = nativeButtonsChoice.value;
			if (nativeButtonsChoice != null) {
				nativeButtonsChoice.onChange(function(val:String) {
					buttonsUsed = val;
					syncHUD(true);
				});
			}

			nativePromptChoice = settingsObj.choice(
				"hud_prompt_mode",
				"Button Prompts",
				"HUD prompt style: Auto Detect (switches dynamically between controller and keyboard), Keyboard, or Controller.",
				[
					{value: "auto", label: "Auto Detect"},
					{value: "kbm", label: "Keyboard"},
					{value: "controller", label: "Controller"}
				],
				promptMode
			);
			if (nativePromptChoice != null && nativePromptChoice.value != null && nativePromptChoice.value != "") promptMode = nativePromptChoice.value;
			if (nativePromptChoice != null) {
				nativePromptChoice.onChange(function(val:String) {
					promptMode = val;
					applyGlyphPreference();
					syncHUD(true);
				});
			}

			nativeControllerStyleChoice = settingsObj.choice(
				"hud_controller_style",
				"Controller Style",
				"Icon style used when controller prompts are displayed on the HUD (DualSense, Xbox, Nintendo Switch, etc.).",
				[
					{value: "auto", label: "Auto Detect"},
					{value: "ps5", label: "DualSense"},
					{value: "ps4", label: "DualShock 4"},
					{value: "xbox", label: "Xbox Series/One"},
					{value: "xbox360", label: "Xbox 360"},
					{value: "switch", label: "Nintendo Switch"},
					{value: "steamdeck", label: "Steam Deck"},
					{value: "ps3", label: "DualShock 3"},
					{value: "xboxone", label: "Xbox One"},
					{value: "steam", label: "Steam Controller"},
					{value: "wiiu", label: "Wii U"},
					{value: "wii", label: "Wii"},
					{value: "psvita", label: "PS Vita"},
					{value: "psmove", label: "PS Move"},
					{value: "googlestadia", label: "Google Stadia"},
					{value: "amazonluna", label: "Amazon Luna"},
					{value: "ouya", label: "Ouya"}
				],
				controllerStyle
			);
			if (nativeControllerStyleChoice != null && nativeControllerStyleChoice.value != null && nativeControllerStyleChoice.value != "") controllerStyle = nativeControllerStyleChoice.value;
			if (nativeControllerStyleChoice != null) {
				nativeControllerStyleChoice.onChange(function(val:String) {
					controllerStyle = val;
					applyGlyphPreference();
					syncHUD(true);
				});
			}

			nativeKeyboardStyleChoice = settingsObj.choice(
				"hud_keyboard_style",
				"Keyboard Style",
				"Visual style used when keyboard prompts are active: Text (labels), Dark Keys, or Light Keys.",
				[
					{value: "text", label: "Text"},
					{value: "kbm_dark", label: "Dark Keys"},
					{value: "kbm_light", label: "Light Keys"}
				],
				keyboardStyle
			);
			if (nativeKeyboardStyleChoice != null && nativeKeyboardStyleChoice.value != null && nativeKeyboardStyleChoice.value != "") keyboardStyle = nativeKeyboardStyleChoice.value;
			if (nativeKeyboardStyleChoice != null) {
				nativeKeyboardStyleChoice.onChange(function(val:String) {
					keyboardStyle = val;
					applyGlyphPreference();
					syncHUD(true);
				});
			}

			nativeSettingsRegistered = true;
			context.log("HUD Input Selector registered settings natively via Mod API.");
			applyGlyphPreference();
			syncHUD(true);
			return true;
		} catch (eNative:Dynamic) {
			if (context != null) context.log("Error registering via Mod API settings: " + Std.string(eNative));
			return false;
		}
	}

	function ensureCustomLocalGlyphs():Void {
		if (aliasesInjected || facade == null) return;
		var sim:Dynamic = Reflect.field(facade, "steamInputManager");
		if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
		if (sim == null) return;
		try {
			var lg:Dynamic = Reflect.field(sim, "mLocalGlyphs");
			if (lg != null) {
				try {
					Reflect.callMethod(lg, Reflect.field(lg, "getGlyphPath"), ["dummy_init_path.png", ""]);
					if (!aliasesInjected) {
						var pathsByName:Dynamic = Reflect.field(lg, "mGlyphPathsByName");
						injectGlyphAliases(pathsByName);
					}
				} catch (e2:Dynamic) {}
			}
		} catch (e:Dynamic) {}
	}
	public static var aliasesInjected:Bool = false;

	public static function normKey(value:String):String {
		if (value == null) return "";
		var out = new StringBuf();
		var lower = value.toLowerCase();
		for (i in 0...lower.length) {
			var code = lower.charCodeAt(i);
			if ((code >= 97 && code <= 122) || (code >= 48 && code <= 57)) {
				out.addChar(code);
			}
		}
		return out.toString();
	}

	public static function injectGlyphAliases(dict:Dynamic):Void {
		if (dict == null || aliasesInjected) return;
		try {
			var aliasMap = [
				// Ouya aliases
				"ouyalb" => "ouyal1",
				"ouyarb" => "ouyar1",
				"ouyalt" => "ouyal2",
				"ouyart" => "ouyar2",
				// Wii aliases
				"wiix" => "wii1",
				"wiiy" => "wii2",
				"wiilb" => "wiic",
				"wiirb" => "wiiz",
				// PS Move aliases
				"psmovelb" => "psmovet",
				"psmoverb" => "psmovemove",
				// PS Vita typo alias
				"vitabumperleft" => "vitabumpterleft"
			];

			for (aliasKey in aliasMap.keys()) {
				var targetKey = aliasMap.get(aliasKey);
				var targetVal:Dynamic = Dictionaries.get(dict, targetKey);
				if (targetVal != null && Dictionaries.get(dict, aliasKey) == null) {
					Dictionaries.set(dict, aliasKey, targetVal);
				}
			}

			aliasesInjected = true;
		} catch (ex:Dynamic) {}
	}

	public static function getCandidateForKeyCode(code:Int, isDark:Bool):String {
		if (code <= 0) return "";
		var suffix = isDark ? "Dark" : "Light";
		if (code >= 65 && code <= 90) {
			return String.fromCharCode(code).toUpperCase() + "_Key_" + suffix;
		}
		if (code >= 48 && code <= 57) {
			return String.fromCharCode(code) + "_Key_" + suffix;
		}
		if (code >= 96 && code <= 105) {
			return (code - 96) + "_Key_" + suffix;
		}
		if (code >= 112 && code <= 123) {
			return "F" + (code - 112 + 1) + "_Key_" + suffix;
		}
		return switch (code) {
			case 32: "Space_Key_" + suffix;
			case 27: "Esc_Key_" + suffix;
			case 13: "Enter_Key_" + suffix;
			case 16: "Shift_Key_" + suffix;
			case 17: "Ctrl_Key_" + suffix;
			case 18: "Alt_Key_" + suffix;
			case 9: "Tab_Key_" + suffix;
			case 8: "Backspace_Key_" + suffix;
			case 20: "Caps_Lock_Key_" + suffix;
			case 37: "Arrow_Left_Key_" + suffix;
			case 38: "Arrow_Up_Key_" + suffix;
			case 39: "Arrow_Right_Key_" + suffix;
			case 40: "Arrow_Down_Key_" + suffix;
			case 45: "Insert_Key_" + suffix;
			case 46: "Del_Key_" + suffix;
			case 36: "Home_Key_" + suffix;
			case 35: "End_Key_" + suffix;
			case 33: "Page_Up_Key_" + suffix;
			case 34: "Page_Down_Key_" + suffix;
			case 186: "Semicolon_Key_" + suffix;
			case 187, 107: "Plus_Key_" + suffix;
			case 188: "Mark_Left_Key_" + suffix;
			case 189, 109: "Minus_Key_" + suffix;
			case 190, 110: "Mark_Right_Key_" + suffix;
			case 191, 111: "Slash_Key_" + suffix;
			case 192: "Tilda_Key_" + suffix;
			case 219: "Bracket_Left_Key_" + suffix;
			case 221: "Bracket_Right_Key_" + suffix;
			case 222: "Quote_Key_" + suffix;
			default: "";
		};
	}

	public static function getStyleCandidates(pref:String, ctrl:String):Array<String> {
		var list:Array<String> = [];
		var normPref = toPreferenceStyleName(pref);
		switch (normPref) {
			case "PS5":
				if (ctrl == "Menu") list.push("PS5_Options");
				if (ctrl == "View") list.push("PS5_Share");
				if (ctrl == "X") list.push("PS5_Square");
				if (ctrl == "Y") list.push("PS5_Triangle");
				if (ctrl == "B") list.push("PS5_Circle");
				if (ctrl == "A") list.push("PS5_Cross");
				if (ctrl == "LB") list.push("PS5_L1");
				if (ctrl == "RB") list.push("PS5_R1");
				if (ctrl == "LT") list.push("PS5_L2");
				if (ctrl == "RT") list.push("PS5_R2");
				list.push("PS5_" + ctrl);
			case "PS4":
				if (ctrl == "Menu") list.push("PS4_Options");
				if (ctrl == "View") list.push("PS4_Share");
				if (ctrl == "X") list.push("PS4_Square");
				if (ctrl == "Y") list.push("PS4_Triangle");
				if (ctrl == "B") list.push("PS4_Circle");
				if (ctrl == "A") list.push("PS4_Cross");
				if (ctrl == "LB") list.push("PS4_L1");
				if (ctrl == "RB") list.push("PS4_R1");
				if (ctrl == "LT") list.push("PS4_L2");
				if (ctrl == "RT") list.push("PS4_R2");
				list.push("PS4_" + ctrl);
			case "PS3":
				if (ctrl == "Menu") list.push("PS3_Start");
				if (ctrl == "View") list.push("PS3_Select");
				if (ctrl == "X") list.push("PS3_Square");
				if (ctrl == "Y") list.push("PS3_Triangle");
				if (ctrl == "B") list.push("PS3_Circle");
				if (ctrl == "A") list.push("PS3_Cross");
				if (ctrl == "LB") list.push("PS3_L1");
				if (ctrl == "RB") list.push("PS3_R1");
				if (ctrl == "LT") list.push("PS3_L2");
				if (ctrl == "RT") list.push("PS3_R2");
				list.push("PS3_" + ctrl);
			case "PS Vita":
				if (ctrl == "Menu") list.push("Vita_Start");
				if (ctrl == "View") list.push("Vita_Select");
				if (ctrl == "X") list.push("Vita_Square");
				if (ctrl == "Y") list.push("Vita_Triangle");
				if (ctrl == "B") list.push("Vita_Circle");
				if (ctrl == "A") list.push("Vita_Cross");
				if (ctrl == "LB") {
					list.push("Vita_Bumpter_Left");
					list.push("Vita_Bumper_Left");
				}
				if (ctrl == "RB") list.push("Vita_Bumper_Right");
				list.push("Vita_" + ctrl);
			case "PS Move":
				if (ctrl == "Menu") list.push("PSMove_Start");
				if (ctrl == "View") list.push("PSMove_Select");
				if (ctrl == "X") list.push("PSMove_Square");
				if (ctrl == "Y") list.push("PSMove_Triangle");
				if (ctrl == "B") list.push("PSMove_Circle");
				if (ctrl == "A") list.push("PSMove_Cross");
				if (ctrl == "LB") {
					list.push("PSMove_T");
					list.push("PSMove_LT");
					list.push("PSMove_Move");
				}
				if (ctrl == "RB") {
					list.push("PSMove_Move");
					list.push("PSMove_RT");
					list.push("PSMove_T");
				}
				list.push("PSMove_" + ctrl);
			case "Xbox Series X":
				if (ctrl == "Menu") list.push("XboxSeriesX_Menu");
				if (ctrl == "View") {
					list.push("XboxSeriesX_View");
					list.push("360_Back");
				}
				list.push("XboxSeriesX_" + ctrl);
			case "Xbox One":
				if (ctrl == "Menu") list.push("XboxOne_Menu");
				if (ctrl == "View") {
					list.push("XboxSeriesX_View");
					list.push("360_Back");
				}
				list.push("XboxOne_" + ctrl);
			case "Xbox 360":
				if (ctrl == "Menu") list.push("360_Start");
				if (ctrl == "View") list.push("360_Back");
				list.push("360_" + ctrl);
			case "Switch":
				if (ctrl == "Menu") list.push("Switch_Plus");
				if (ctrl == "View") list.push("Switch_Minus");
				list.push("Switch_" + ctrl);
			case "Steam Deck":
				if (ctrl == "Menu") list.push("SteamDeck_Menu");
				if (ctrl == "View") {
					list.push("SteamDeck_View");
					list.push("XboxSeriesX_View");
					list.push("360_Back");
				}
				if (ctrl == "LB") list.push("SteamDeck_L1");
				if (ctrl == "RB") list.push("SteamDeck_R1");
				if (ctrl == "LT") list.push("SteamDeck_L2");
				if (ctrl == "RT") list.push("SteamDeck_R2");
				list.push("SteamDeck_" + ctrl);
			case "Steam":
				if (ctrl == "Menu") list.push("Steam_Start");
				if (ctrl == "View") list.push("Steam_Back");
				list.push("Steam_" + ctrl);
			case "WiiU":
				if (ctrl == "Menu") list.push("WiiU_Plus");
				if (ctrl == "View") list.push("WiiU_Minus");
				if (ctrl == "LB") list.push("WiiU_L");
				if (ctrl == "RB") list.push("WiiU_R");
				if (ctrl == "LT") list.push("WiiU_ZL");
				if (ctrl == "RT") list.push("WiiU_ZR");
				list.push("WiiU_" + ctrl);
			case "Wii":
				if (ctrl == "Menu") list.push("Wii_Plus");
				if (ctrl == "View") list.push("Wii_Minus");
				if (ctrl == "A") list.push("Wii_A");
				if (ctrl == "B") list.push("Wii_B");
				if (ctrl == "X") {
					list.push("Wii_1");
					list.push("Wii_C");
				}
				if (ctrl == "Y") {
					list.push("Wii_2");
					list.push("Wii_Z");
				}
				if (ctrl == "LB") {
					list.push("Wii_C");
					list.push("Wii_1");
					list.push("Wii_Minus");
				}
				if (ctrl == "RB") {
					list.push("Wii_Z");
					list.push("Wii_2");
					list.push("Wii_Plus");
				}
				if (ctrl == "Dpad_Left") list.push("Wii_Dpad_Left");
				if (ctrl == "Dpad_Down") list.push("Wii_Dpad_Down");
				if (ctrl == "Dpad_Right") list.push("Wii_Dpad_Right");
				if (ctrl == "Dpad_Up") list.push("Wii_Dpad_Up");
				list.push("Wii_" + ctrl);
			case "Google Stadia":
				if (ctrl == "Menu") list.push("Stadia_Menu");
				if (ctrl == "View") list.push("Stadia_Select");
				if (ctrl == "LB") list.push("Stadia_L1");
				if (ctrl == "RB") list.push("Stadia_R1");
				if (ctrl == "LT") list.push("Stadia_L2");
				if (ctrl == "RT") list.push("Stadia_R2");
				list.push("Stadia_" + ctrl);
			case "Amazon Luna":
				if (ctrl == "Menu") list.push("Luna_Menu");
				if (ctrl == "View") list.push("Luna_Circle");
				list.push("Luna_" + ctrl);
			case "Ouya":
				if (ctrl == "Menu") list.push("Ouya_Menu");
				if (ctrl == "A") list.push("Ouya_O");
				if (ctrl == "B") list.push("Ouya_A");
				if (ctrl == "X") list.push("Ouya_U");
				if (ctrl == "Y") list.push("Ouya_Y");
				if (ctrl == "LB") list.push("Ouya_L1");
				if (ctrl == "RB") list.push("Ouya_R1");
				if (ctrl == "LT") list.push("Ouya_L2");
				if (ctrl == "RT") list.push("Ouya_R2");
				list.push("Ouya_" + ctrl);
		}

		// Xbox Series X fallback candidates
		if (ctrl == "Menu") list.push("XboxSeriesX_Menu");
		if (ctrl == "View") list.push("XboxSeriesX_View");
		list.push("XboxSeriesX_" + ctrl);

		return list;
	}

	public static function toPreferenceStyleName(styleId:String):String {
		return switch (styleId != null ? styleId.toLowerCase() : "") {
			case "ps5": "PS5";
			case "ps4": "PS4";
			case "ps3": "PS3";
			case "psvita": "PS Vita";
			case "psmove": "PS Move";
			case "xbox", "xboxseries", "xboxseriesx": "Xbox Series X";
			case "xboxone": "Xbox One";
			case "xbox360": "Xbox 360";
			case "switch": "Switch";
			case "steamdeck": "Steam Deck";
			case "steam": "Steam";
			case "wiiu": "WiiU";
			case "wii": "Wii";
			case "googlestadia": "Google Stadia";
			case "amazonluna": "Amazon Luna";
			case "ouya": "Ouya";
			case "ps vita": "PS Vita";
			case "ps move": "PS Move";
			case "xbox series x": "Xbox Series X";
			case "xbox one": "Xbox One";
			case "xbox 360": "Xbox 360";
			case "steam deck": "Steam Deck";
			case "google stadia": "Google Stadia";
			case "amazon luna": "Amazon Luna";
			default: "Xbox 360";
		};
	}

	public static function getFallbackControllerPath(pref:String, ctrl:String):String {
		var norm = toPreferenceStyleName(pref);
		return switch (norm) {
			case "PS5":
				switch (ctrl) {
					case "A": "./Resources/Glyphs/PS5/PS5_Cross.png";
					case "B": "./Resources/Glyphs/PS5/PS5_Circle.png";
					case "X": "./Resources/Glyphs/PS5/PS5_Square.png";
					case "Y": "./Resources/Glyphs/PS5/PS5_Triangle.png";
					case "LB": "./Resources/Glyphs/PS5/PS5_L1.png";
					case "RB": "./Resources/Glyphs/PS5/PS5_R1.png";
					case "LT": "./Resources/Glyphs/PS5/PS5_L2.png";
					case "RT": "./Resources/Glyphs/PS5/PS5_R2.png";
					case "Menu": "./Resources/Glyphs/PS5/PS5_Options.png";
					case "View": "./Resources/Glyphs/PS5/PS5_Share.png";
					case "Dpad_Left": "./Resources/Glyphs/PS5/PS5_Dpad_Left.png";
					case "Dpad_Down": "./Resources/Glyphs/PS5/PS5_Dpad_Down.png";
					default: "./Resources/Glyphs/PS5/PS5_" + ctrl + ".png";
				};
			case "PS4":
				switch (ctrl) {
					case "A": "./Resources/Glyphs/Others/PS4/PS4_Cross.png";
					case "B": "./Resources/Glyphs/Others/PS4/PS4_Circle.png";
					case "X": "./Resources/Glyphs/Others/PS4/PS4_Square.png";
					case "Y": "./Resources/Glyphs/Others/PS4/PS4_Triangle.png";
					case "LB": "./Resources/Glyphs/Others/PS4/PS4_L1.png";
					case "RB": "./Resources/Glyphs/Others/PS4/PS4_R1.png";
					case "LT": "./Resources/Glyphs/Others/PS4/PS4_L2.png";
					case "RT": "./Resources/Glyphs/Others/PS4/PS4_R2.png";
					case "Menu": "./Resources/Glyphs/Others/PS4/PS4_Options.png";
					case "View": "./Resources/Glyphs/Others/PS4/PS4_Share.png";
					case "Dpad_Left": "./Resources/Glyphs/Others/PS4/PS4_Dpad_Left.png";
					case "Dpad_Down": "./Resources/Glyphs/Others/PS4/PS4_Dpad_Down.png";
					default: "./Resources/Glyphs/Others/PS4/PS4_" + ctrl + ".png";
				};
			case "PS3":
				switch (ctrl) {
					case "A": "./Resources/Glyphs/Others/PS3/PS3_Cross.png";
					case "B": "./Resources/Glyphs/Others/PS3/PS3_Circle.png";
					case "X": "./Resources/Glyphs/Others/PS3/PS3_Square.png";
					case "Y": "./Resources/Glyphs/Others/PS3/PS3_Triangle.png";
					case "LB": "./Resources/Glyphs/Others/PS3/PS3_L1.png";
					case "RB": "./Resources/Glyphs/Others/PS3/PS3_R1.png";
					case "LT": "./Resources/Glyphs/Others/PS3/PS3_L2.png";
					case "RT": "./Resources/Glyphs/Others/PS3/PS3_R2.png";
					case "Menu": "./Resources/Glyphs/Others/PS3/PS3_Start.png";
					case "View": "./Resources/Glyphs/Others/PS3/PS3_Select.png";
					default: "./Resources/Glyphs/Others/PS3/PS3_" + ctrl + ".png";
				};
			case "Xbox Series X":
				switch (ctrl) {
					case "Menu": "./Resources/Glyphs/Xbox Series/XboxSeriesX_Menu.png";
					case "View": "./Resources/Glyphs/Xbox Series/XboxSeriesX_View.png";
					default: "./Resources/Glyphs/Xbox Series/XboxSeriesX_" + ctrl + ".png";
				};
			case "Xbox One":
				switch (ctrl) {
					case "Menu": "./Resources/Glyphs/Others/Xbox One/XboxOne_Menu.png";
					case "View": "./Resources/Glyphs/Others/Xbox One/XboxOne_Windows.png";
					default: "./Resources/Glyphs/Others/Xbox One/XboxOne_" + ctrl + ".png";
				};
			case "Switch":
				switch (ctrl) {
					case "Menu": "./Resources/Glyphs/Switch/Switch_Plus.png";
					case "View": "./Resources/Glyphs/Switch/Switch_Minus.png";
					default: "./Resources/Glyphs/Switch/Switch_" + ctrl + ".png";
				};
			case "Steam Deck":
				switch (ctrl) {
					case "Menu": "./Resources/Glyphs/Steam Deck/SteamDeck_Menu.png";
					case "View": "./Resources/Glyphs/Steam Deck/SteamDeck_Inventory.png";
					case "LB": "./Resources/Glyphs/Steam Deck/SteamDeck_L1.png";
					case "RB": "./Resources/Glyphs/Steam Deck/SteamDeck_R1.png";
					default: "./Resources/Glyphs/Steam Deck/SteamDeck_" + ctrl + ".png";
				};
			default: // "Xbox 360"
				switch (ctrl) {
					case "Menu": "./Resources/Glyphs/Others/Xbox 360/360_Start.png";
					case "View": "./Resources/Glyphs/Others/Xbox 360/360_Back.png";
					default: "./Resources/Glyphs/Others/Xbox 360/360_" + ctrl + ".png";
				};
		};
	}
}
