package mods.hud_input_selector;

import brain.logger.Logger;
import facade.DBFacade;
import openfl.events.Event;
import openfl.events.KeyboardEvent;
import openfl.events.MouseEvent;
import mods.api.Context;
import mods.api.Mod;
import mods.custom_settings_api.CustomSettingsApi;
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
	var keyboardStyle:String = "text"; // "text", "kbm_dark", "kbm_light"

	var lastUsedDevice:String = "kbm"; // "kbm" or "controller"
	var settingsRegistered:Bool = false;
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

		// Try registering with CustomSettingsApi immediately
		tryRegisterSettings();

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
		haxe.Timer.delay(function() {
			syncHUD(true);
		}, 50);
		haxe.Timer.delay(function() {
			syncHUD(true);
		}, 200);
		haxe.Timer.delay(function() {
			syncHUD(true);
		}, 500);
		haxe.Timer.delay(function() {
			syncHUD(true);
		}, 1000);
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
			// Try registering settings if not yet loaded
			if (!settingsRegistered) {
				tryRegisterSettings();
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
						if ((vx * vx + vy * vy) > 0.05) {
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
								for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
									var asdCls:Dynamic = Type.resolveClass(clsName);
									if (asdCls != null) {
										var keysFn:Dynamic = Reflect.field(asdCls, "keysIn");
										if (keysFn != null) {
											var iter:Dynamic = Reflect.callMethod(asdCls, keysFn, [dict]);
											if (iter != null && Reflect.callMethod(iter, Reflect.field(iter, "hasNext"), []) == true) {
												return true;
											}
										}
									}
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
								var vec:Dynamic = getDictValue(analogs, actName);
								if (vec != null) {
									var vx:Float = Reflect.field(vec, "x") != null ? Reflect.field(vec, "x") : 0.0;
									var vy:Float = Reflect.field(vec, "y") != null ? Reflect.field(vec, "y") : 0.0;
									if ((vx * vx + vy * vy) > 0.05) {
										return true;
									}
								}
							}
							for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
								var asdCls:Dynamic = Type.resolveClass(clsName);
								if (asdCls != null) {
									var valFn:Dynamic = Reflect.field(asdCls, "valuesIn");
									if (valFn != null) {
										var iter:Dynamic = Reflect.callMethod(asdCls, valFn, [analogs]);
										if (iter != null) {
											while (Reflect.callMethod(iter, Reflect.field(iter, "hasNext"), []) == true) {
												var vec:Dynamic = Reflect.callMethod(iter, Reflect.field(iter, "next"), []);
												if (vec != null) {
													var vx:Float = Reflect.field(vec, "x") != null ? Reflect.field(vec, "x") : 0.0;
													var vy:Float = Reflect.field(vec, "y") != null ? Reflect.field(vec, "y") : 0.0;
													if ((vx * vx + vy * vy) > 0.05) {
														return true;
													}
												}
											}
										}
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
			if (Reflect.field(sim, "isSteamInputReady") == true) return true;
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
		if (isSyncingHUD) return;
		try {
			var state = getDesiredPromptState();
			if (state == "kbm") {
				syncHUD(true);
				return;
			}
			if (promptMode == "controller" || promptMode == "kbm") {
				syncHUD(true);
				haxe.Timer.delay(function() {
					syncHUD(true);
				}, 60);
			} else if (controllerStyle == "auto") {
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
				haxe.Timer.delay(function() {
					syncHUD(true);
				}, 60);
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
				haxe.Timer.delay(function() {
					syncHUD(true);
				}, 60);
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
		isSyncingHUD = true;
		try {
			lastSyncTimestamp = Date.now().getTime();
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

	function setDictValue(dict:Dynamic, key:String, val:Dynamic):Void {
		if (dict == null || key == null) return;
		for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
			try {
				var cls:Dynamic = Type.resolveClass(clsName);
				if (cls != null) {
					var fn:Dynamic = Reflect.field(cls, "setIn");
					if (fn != null) {
						Reflect.callMethod(cls, fn, [dict, key, val]);
						return;
					}
				}
			} catch (e:Dynamic) {}
		}
		for (clsName in ["ASCompat", "_ASCompat.ASCompat_Impl_"]) {
			try {
				var cls:Dynamic = Type.resolveClass(clsName);
				if (cls != null) {
					var fn:Dynamic = Reflect.field(cls, "setIndexed");
					if (fn != null) {
						Reflect.callMethod(cls, fn, [dict, key, val]);
						return;
					}
				}
			} catch (e:Dynamic) {}
		}
		try {
			dict.set(key, val);
		} catch (e:Dynamic) {}
	}

	static function isUndefined(val:Dynamic):Bool {
		if (val == null) return true;
		for (clsName in ["ASCompat", "_ASCompat.ASCompat_Impl_"]) {
			try {
				var cls:Dynamic = Type.resolveClass(clsName);
				if (cls != null) {
					var fn:Dynamic = Reflect.field(cls, "isUndefinedValue");
					if (fn != null && Reflect.callMethod(cls, fn, [val]) == true) return true;
				}
			} catch (e:Dynamic) {}
		}
		var str = Std.string(val);
		return str == "undefined" || str == "null" || str == "";
	}

	function getDictValue(dict:Dynamic, key:String):Dynamic {
		if (dict == null || key == null) return null;
		for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
			try {
				var cls:Dynamic = Type.resolveClass(clsName);
				if (cls != null) {
					var fnGet:Dynamic = Reflect.field(cls, "getIn");
					if (fnGet != null) {
						var res:Dynamic = Reflect.callMethod(cls, fnGet, [dict, key]);
						if (res != null && !isUndefined(res)) return res;
					}
					var fn:Dynamic = Reflect.field(cls, "getString");
					if (fn != null) {
						var res:Dynamic = Reflect.callMethod(cls, fn, [dict, key]);
						if (res != null && !isUndefined(res) && res != "") return res;
					}
				}
			} catch (e:Dynamic) {}
		}
		try {
			var dVal = dict.get(key);
			if (dVal != null && !isUndefined(dVal)) return dVal;
		} catch (e:Dynamic) {}
		return null;
	}

	function removeDictValue(dict:Dynamic, key:String):Void {
		if (dict == null || key == null) return;
		for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
			try {
				var cls:Dynamic = Type.resolveClass(clsName);
				if (cls != null) {
					var fn:Dynamic = Reflect.field(cls, "removeIn");
					if (fn != null) {
						Reflect.callMethod(cls, fn, [dict, key]);
						return;
					}
					var fnDel:Dynamic = Reflect.field(cls, "delete");
					if (fnDel != null) {
						Reflect.callMethod(cls, fnDel, [dict, key]);
						return;
					}
				}
			} catch (e:Dynamic) {}
		}
		try {
			dict.remove(key);
		} catch (e:Dynamic) {}
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

	function detachStarlingListeners(sHud:Dynamic):Void {
		if (sHud == null) return;
		try {
			var sEvents:Dynamic = Reflect.field(sHud, "mEvents");
			if (sEvents != null) {
				Reflect.callMethod(sEvents, Reflect.field(sEvents, "removeListener"), ["OnSteamInputGlyphsChanged"]);
				Reflect.callMethod(sEvents, Reflect.field(sEvents, "removeListener"), ["ControllerConnectionChangedEvent"]);
			}
		} catch (e:Dynamic) {}
		try {
			var task:Dynamic = Reflect.field(sHud, "mGlyphTask");
			if (task != null) {
				try { Reflect.callMethod(task, Reflect.field(task, "destroy"), []); } catch (eT:Dynamic) {}
				Reflect.setField(sHud, "mGlyphTask", null);
			}
		} catch (e2:Dynamic) {}
	}

	function setStarlingActionGlyph(sHud:Dynamic, action:String, owner:Dynamic, path:String, x:Float, y:Float, size:Float = 25, height:Float = 0):Void {
		if (sHud == null || owner == null || path == null || path == "") return;
		try {
			var container:DisplayObjectContainer = null;
			try { container = cast owner; } catch (eC:Dynamic) {}
			if (container == null) return;

			var assets:AssetLoadingComponent = null;
			try { assets = cast Reflect.field(sHud, "mAssets"); } catch (eA:Dynamic) {}
			if (assets == null) return;

			var glyphGeneration:Int = Reflect.field(sHud, "mGlyphGeneration");
			var texturesDict:Dynamic = Reflect.field(sHud, "mGlyphTextures");
			var pixelsDict:Dynamic = Reflect.field(sHud, "mGlyphPixels");
			var pathsDict:Dynamic = Reflect.field(sHud, "mGlyphPaths");
			var glyphsDict:Dynamic = Reflect.field(sHud, "mStarlingGlyphs");

			assets.getImageAsset(path, function(param1:ImageAsset) {
				try {
					var curGen:Int = Reflect.field(sHud, "mGlyphGeneration");
					var destroyed:Bool = Reflect.field(sHud, "mDestroyed") == true;
					if (destroyed || curGen != glyphGeneration) return;
					if (param1 == null || param1.image == null || param1.image.bitmapData == null) return;

					var bmd:flash.display.BitmapData = param1.image.bitmapData;
					var tex:Texture = null;
					try {
						tex = cast getDictValue(texturesDict, path);
					} catch (eT:Dynamic) {}
					if (tex == null) {
						tex = Texture.fromBitmapData(bmd);
						if (tex != null) setDictValue(texturesDict, path, tex);
					}
					if (tex == null) return;

					if (pixelsDict != null) {
						setDictValue(pixelsDict, path, bmd);
					}
					if (pathsDict != null) {
						setDictValue(pathsDict, action, path);
					}

					var oldImg:DisplayObject = null;
					try {
						oldImg = cast getDictValue(glyphsDict, action);
					} catch (eO:Dynamic) {}
					if (oldImg != null) {
						oldImg.removeFromParent(true);
					}

					var newImg:Image = new Image(tex);
					newImg.touchable = false;
					newImg.x = x;
					newImg.y = y;
					newImg.width = size;
					newImg.height = height > 0 ? height : size;
					container.addChild(newImg);
					setDictValue(glyphsDict, action, newImg);
				} catch (eCb:Dynamic) {}
			});
		} catch (e:Dynamic) {}
	}

	function setStarlingTopRightGlyph(sHud:Dynamic, action:String, owner:Dynamic, path:String, gear:Bool):Void {
		if (sHud == null || owner == null || path == null || path == "") return;
		try {
			var sx:Float = 1.0;
			var sy:Float = 1.0;
			try {
				if (Reflect.field(owner, "scaleX") != null) sx = Reflect.field(owner, "scaleX");
				if (Reflect.field(owner, "scaleY") != null) sy = Reflect.field(owner, "scaleY");
			} catch (eS:Dynamic) {}
			var pos:Dynamic = null;
			var sz:Dynamic = null;
			try {
				var htrCls:Dynamic = Type.resolveClass("uI.hud.HudTopRightLayout");
				if (htrCls != null) {
					pos = Reflect.callMethod(htrCls, Reflect.field(htrCls, "glyphPosition"), [gear, sx, sy]);
					sz = Reflect.callMethod(htrCls, Reflect.field(htrCls, "glyphSize"), [sx, sy]);
				}
			} catch (eHtr:Dynamic) {}
			var posX:Float = pos != null ? pos.x : (gear ? 3.275 : 1.375);
			var posY:Float = pos != null ? pos.y : (gear ? -32.75 : -13.35);
			var szW:Float = sz != null ? sz.x : (39.477 / sx);
			var szH:Float = sz != null ? sz.y : (39.477 / sy);
			setStarlingActionGlyph(sHud, action, owner, path, posX, posY, szW, szH);
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
					var p:Dynamic = getDictValue(glyphPaths, act);
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
				var img:Dynamic = getDictValue(dict, action);
				if (img != null) {
					if (Reflect.field(img, "removeFromParent") != null) {
						Reflect.callMethod(img, Reflect.field(img, "removeFromParent"), [true]);
					}
					removeDictValue(dict, action);
				}
			}
		} catch (e1:Dynamic) {}
		try {
			var pDict:Dynamic = Reflect.field(sHud, "mGlyphPaths");
			if (pDict != null) {
				removeDictValue(pDict, action);
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
		removeCloseGlyph(sHud);
		removeActionGlyph(sHud, "open_options_menu");
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
				if (sHud.node("close") == null) return false;
				if (sHud.node("UI_weapons.weapon_z") == null) return false;
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
				detachStarlingListeners(sHud);

				if (hud != lastEnforcedHud || deviceKey != lastEnforcedDevice) {
					if (!isHudReady(hud)) return;
					lastEnforcedHud = hud;
					lastEnforcedDevice = deviceKey;
					lastSyncTimestamp = getTimestamp();
					syncHUD(true);
					return;
				}

				if (state == "kbm") {
					if (keyboardStyle == "text") {
						// Text mode: ensure labels are visible
						sHud.visible("consumables_01.label", true);
						sHud.visible("consumables_02.label", true);
						sHud.visible("UI_weapons.weapon_z.label", true);
						sHud.visible("UI_weapons.weapon_x.label", true);
						sHud.visible("UI_weapons.weapon_c.label", true);

						var bKey = getActionDisplayName("useDungeonBuster");
						var pressKeyStr = "Press " + bKey;
						try {
							var locCls:Dynamic = Type.resolveClass("facade.Locale");
							if (locCls != null) {
								pressKeyStr = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_KEYBOARD"]) + bKey;
							}
						} catch (eLoc:Dynamic) {}
						var paths:Array<String> = [
							"UI_buster_active.buster_activated.up.db_pressbutton_text",
							"UI_buster_active.buster_activated.over.mc.db_pressbutton_text"
						];
						for (p in paths) {
							var nd:Dynamic = sHud.node(p);
							if (nd != null) {
								var curTxt:String = null;
								try {
									curTxt = Reflect.getProperty(nd, "text");
									if (curTxt == null) curTxt = Reflect.field(nd, "mText");
								} catch (eTxt:Dynamic) {}
								if (curTxt != pressKeyStr) {
									sHud.text(p, pressKeyStr, true);
									if (Reflect.field(nd, "setHudOffset") != null) {
										Reflect.callMethod(nd, Reflect.field(nd, "setHudOffset"), [0, 0]);
									}
								}
							}
						}
					} else {
						// Dark / Light Keys mode: ensure labels stay hidden
						sHud.visible("consumables_01.label", false);
						sHud.visible("consumables_02.label", false);
						sHud.visible("UI_weapons.weapon_z.label", false);
						sHud.visible("UI_weapons.weapon_x.label", false);
						sHud.visible("UI_weapons.weapon_c.label", false);

						var pressStr = "Press ";
						try {
							var locCls:Dynamic = Type.resolveClass("facade.Locale");
							if (locCls != null) {
								pressStr = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_CONTROLLER"]);
							}
						} catch (eLoc:Dynamic) {}
						var paths:Array<String> = [
							"UI_buster_active.buster_activated.up.db_pressbutton_text",
							"UI_buster_active.buster_activated.over.mc.db_pressbutton_text"
						];
						for (p in paths) {
							var nd:Dynamic = sHud.node(p);
							if (nd != null) {
								var curTxt:String = null;
								try {
									curTxt = Reflect.getProperty(nd, "text");
									if (curTxt == null) curTxt = Reflect.field(nd, "mText");
								} catch (eTxt:Dynamic) {}
								if (curTxt != pressStr) {
									sHud.text(p, pressStr, true);
									if (Reflect.field(nd, "setHudOffset") != null) {
										Reflect.callMethod(nd, Reflect.field(nd, "setHudOffset"), [-5, 0]);
									}
								}
							}
						}
					}
				} else {
					// Controller mode: ensure keyboard labels stay hidden
					sHud.visible("consumables_01.label", false);
					sHud.visible("consumables_02.label", false);
					sHud.visible("UI_weapons.weapon_z.label", false);
					sHud.visible("UI_weapons.weapon_x.label", false);
					sHud.visible("UI_weapons.weapon_c.label", false);
				}

				// Throttled recovery sync in case the game completely reconstructed the HUD
				var now = getTimestamp();
				if (now - lastSyncTimestamp > 1200) {
					if (state == "controller" && isKeyboardLabelVisible(sHud)) {
						if (isHudReady(hud)) {
							lastSyncTimestamp = now;
							syncHUD(true);
						}
					} else if (state == "kbm" && keyboardStyle == "text" && hasActiveControllerGlyphs(sHud)) {
						if (isHudReady(hud)) {
							lastSyncTimestamp = now;
							syncHUD(true);
						}
					}
				}
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
			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;

				detachStarlingListeners(sHud);

				sHud.clearGlyphs();
				removeCloseGlyph(sHud);
				removeBusterGlyph(sHud);
				removeChatLogGlyph(sHud);
				removeActionGlyph(sHud, "open_options_menu");

				sHud.setAllKeyboardIconsVisibility(true);
				sHud.visible("consumables_01.label", true);
				sHud.visible("consumables_02.label", true);
				sHud.visible("UI_weapons.weapon_z.label", true);
				sHud.visible("UI_weapons.weapon_x.label", true);
				sHud.visible("UI_weapons.weapon_c.label", true);
				sHud.refreshKeyboardLabels();
				var chat:Dynamic = Reflect.field(sHud, "mChat");
				if (chat != null) {
					try { Reflect.callMethod(chat, Reflect.field(chat, "setChatPromptVisible"), [true]); } catch (eC:Dynamic) {}
				}
				updateKeyboardLabels(sHud);

				// In Text mode, do NOT display any keycap on settings gear (clean vanilla behavior)
				var sim:Dynamic = Reflect.field(facade, "steamInputManager");
				if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
				var glyphMap:Dynamic = sim != null ? Reflect.field(sim, "mInputActionNameToControllerGlyphFilePath") : null;
				if (glyphMap != null) {
					var actsToClean = [
						"attack_weapon_1", "attack_weapon_2", "attack_weapon_3",
						"use_consumable_one", "use_consumable_two", "use_dungeon_buster",
						"toggle_menu", "open_options_menu", "toggle_chat_log"
					];
					for (a in actsToClean) {
						removeDictValue(glyphMap, a);
					}
				}

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
			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;

				detachStarlingListeners(sHud);

				sHud.clearGlyphs();
				removeCloseGlyph(sHud);
				removeBusterGlyph(sHud);
				removeChatLogGlyph(sHud);
				removeActionGlyph(sHud, "open_options_menu");

				sHud.setAllKeyboardIconsVisibility(false);
				sHud.visible("consumables_01.label", false);
				sHud.visible("consumables_02.label", false);
				sHud.visible("UI_weapons.weapon_z.label", false);
				sHud.visible("UI_weapons.weapon_x.label", false);
				sHud.visible("UI_weapons.weapon_c.label", false);
				var chat:Dynamic = Reflect.field(sHud, "mChat");
				if (chat != null) {
					try { Reflect.callMethod(chat, Reflect.field(chat, "setChatPromptVisible"), [true]); } catch (eC:Dynamic) {}
				}

				var sim:Dynamic = Reflect.field(facade, "steamInputManager");
				if (sim == null) sim = Reflect.field(facade, "mSteamInputManager");
				var glyphMap:Dynamic = sim != null ? Reflect.field(sim, "mInputActionNameToControllerGlyphFilePath") : null;
				var pathsDict:Dynamic = getLocalGlyphPathsDict();

				var actions = [
					"attack_weapon_1",
					"attack_weapon_2",
					"attack_weapon_3",
					"use_consumable_one",
					"use_consumable_two",
					"use_dungeon_buster",
					"toggle_menu",
					"open_options_menu"
				];

				if (glyphMap != null) {
					for (act in actions) {
						var cand = getSpecialCandidates(style, act);
						var path = findGlyphPath(pathsDict, cand);
						if (path == null || path == "") {
							if (act == "open_options_menu") {
								path = (style == "kbm_light")
									? "./Resources/Glyphs/Keyboard & Mouse/Light/O_Key_Light.png"
									: "./Resources/Glyphs/Keyboard & Mouse/Dark/O_Key_Dark.png";
							} else if (act == "toggle_menu") {
								path = (style == "kbm_light")
									? "./Resources/Glyphs/Keyboard & Mouse/Light/Esc_Key_Light.png"
									: "./Resources/Glyphs/Keyboard & Mouse/Dark/Esc_Key_Dark.png";
							}
						}
						if (path != null && path != "") {
							setDictValue(glyphMap, act, path);
						}
					}
					removeDictValue(glyphMap, "toggle_chat_log");
				}

				if (sHud.node("close") != null) {
					sHud.initStarlingControllerIcons();
					var pressStr = "Press ";
					try {
						var locCls:Dynamic = Type.resolveClass("facade.Locale");
						if (locCls != null) {
							pressStr = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_CONTROLLER"]);
						}
					} catch (eLoc:Dynamic) {}
					var paths:Array<String> = [
						"UI_buster_active.buster_activated.up.db_pressbutton_text",
						"UI_buster_active.buster_activated.over.mc.db_pressbutton_text",
						"UI_buster_glow.buster_text.buster_text_label.db_pressbutton_text"
					];
					for (p in paths) {
						sHud.text(p, pressStr, true);
						var nd:Dynamic = sHud.node(p);
						if (nd != null && Reflect.field(nd, "setHudOffset") != null) {
							Reflect.callMethod(nd, Reflect.field(nd, "setHudOffset"), [-5, 0]);
						}
					}
				}
			}
		} catch (e:Dynamic) {}
	}

	function applyControllerPrompts():Void {
		if (facade == null) return;
		try {
			applyGlyphPreference();

			var pref = toPreferenceStyleName(controllerStyle);
			ensureFallbackGlyphs(pref);

			var hud:Dynamic = Reflect.field(facade, "hud");
			if (hud == null) hud = Reflect.field(facade, "mHud");
			if (hud == null) return;

			var hudName:String = Type.getClassName(Type.getClass(hud));
			if (hudName == "uI.hud.starlingConverted.StarlingHud") {
				var sHud:Dynamic = hud;

				detachStarlingListeners(sHud);

				sHud.clearGlyphs();
				sHud.setAllKeyboardIconsVisibility(false);
				sHud.visible("consumables_01.label", false);
				sHud.visible("consumables_02.label", false);
				sHud.visible("UI_weapons.weapon_z.label", false);
				sHud.visible("UI_weapons.weapon_x.label", false);
				sHud.visible("UI_weapons.weapon_c.label", false);
				var chat:Dynamic = Reflect.field(sHud, "mChat");
				if (chat != null) {
					try { Reflect.callMethod(chat, Reflect.field(chat, "setChatPromptVisible"), [false]); } catch (eC:Dynamic) {}
				}

				var chatPrompt:Dynamic = Reflect.field(sHud, "mChatPrompt");
				if (chatPrompt != null && chatPrompt.logButton != null && chatPrompt.logButton.root != null) {
					sHud.initStarlingGlyph("toggle_chat_log", chatPrompt.logButton.root, 25, -10, 20);
				}
				sHud.initStarlingControllerIcons();
				var pressStr = "Press ";
					try {
						var locCls:Dynamic = Type.resolveClass("facade.Locale");
						if (locCls != null) {
							pressStr = Reflect.callMethod(locCls, Reflect.field(locCls, "getString"), ["PRESS_BUSTER_BUTTON_CONTROLLER"]);
						}
					} catch (eLoc:Dynamic) {}
					var paths:Array<String> = [
						"UI_buster_active.buster_activated.up.db_pressbutton_text",
						"UI_buster_active.buster_activated.over.mc.db_pressbutton_text",
						"UI_buster_glow.buster_text.buster_text_label.db_pressbutton_text"
					];
				for (p in paths) {
					sHud.text(p, pressStr, true);
					var nd:Dynamic = sHud.node(p);
					if (nd != null && Reflect.field(nd, "setHudOffset") != null) {
						Reflect.callMethod(nd, Reflect.field(nd, "setHudOffset"), [-5, 0]);
					}
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
				var p:Dynamic = getDictValue(pathsDict, norm);
				if (p != null && !isUndefined(p)) {
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
				return;
			}

			// Controller mode: clean up any stale keyboard keycap that might have been assigned to toggle_chat_log
			var curLog:Dynamic = getDictValue(glyphMap, "toggle_chat_log");
			if (curLog != null && (Std.string(curLog).indexOf("Key_") != -1 || Std.string(curLog).indexOf("Space") != -1)) {
				removeDictValue(glyphMap, "toggle_chat_log");
			}

			var effectivePref = (pref == null || pref == "" || pref == "auto") ? "Xbox 360" : pref;

			// If controller is connected and style is "auto", try native Steamworks origins first
			var hasController = isAnyControllerConnected();
			if (controllerStyle == "auto" && hasController) {
				try {
					Reflect.callMethod(sim, Reflect.field(sim, "updateActionOrigins"), []);
				} catch (eU:Dynamic) {}
				var testA:Dynamic = getDictValue(glyphMap, "attack_weapon_1");
				if (testA != null && testA != "" && !isUndefined(testA) && testA != "error1") {
					return;
				}
			}

			// Custom style candidates from bundled assets (or fallback when no controller connected)
			for (action in map.keys()) {
				var ctrl = map[action];
				var candidates = getCandidates(effectivePref, ctrl);
				var filePath = findGlyphPath(pathsDict, candidates);
				if (filePath == null || filePath == "" || isUndefined(filePath)) {
					filePath = getFallbackControllerPath(effectivePref, ctrl);
				}
				if (filePath != null && filePath != "" && !isUndefined(filePath)) {
					setDictValue(glyphMap, action, filePath);
				}
			}
		} catch (eFall:Dynamic) {}
	}

	function tryRegisterSettings():Bool {
		if (settingsRegistered) return true;

		// 1. Direct typed call to CustomSettingsApi (both mods in the same compilation world)
		try {
			CustomSettingsApi.addCategory("input_hud", "INPUT HUD", "hud_input_selector");

			CustomSettingsApi.addSimpleChoice(
				"input_hud",
				"hud_buttons_used",
				"BUTTONS USED",
				"Selects which key binding from game controls to display on the HUD: Default (primary) or Alt (secondary).",
				["default", "alt"],
				["Default", "Alt"],
				"default",
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != buttonsUsed) {
						buttonsUsed = s;
						syncHUD(true);
					}
				}
			);

			CustomSettingsApi.addSimpleChoice(
				"input_hud",
				"hud_prompt_mode",
				"BUTTON PROMPTS",
				"HUD prompt style: Auto Detect (switches dynamically between controller and keyboard), Keyboard, or Controller.",
				["auto", "kbm", "controller"],
				["Auto Detect", "Keyboard", "Controller"],
				"auto",
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != promptMode) {
						promptMode = s;
						applyGlyphPreference();
						syncHUD(true);
					}
				}
			);

			CustomSettingsApi.addSimpleChoice(
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
				"auto",
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != controllerStyle) {
						controllerStyle = s;
						applyGlyphPreference();
						syncHUD(true);
					}
				}
			);

			CustomSettingsApi.addSimpleChoice(
				"input_hud",
				"hud_keyboard_style",
				"KEYBOARD STYLE",
				"Visual style used when keyboard prompts are active: Text (labels), Dark Keys, or Light Keys.",
				["text", "kbm_dark", "kbm_light"],
				["Text", "Dark Keys", "Light Keys"],
				"text",
				function(val:Dynamic) {
					var s = Std.string(val);
					if (s != keyboardStyle) {
						keyboardStyle = s;
						applyGlyphPreference();
						syncHUD(true);
					}
				}
			);

			var storedButtons = CustomSettingsApi.getString("hud_buttons_used", "default");
			if (storedButtons != null && storedButtons != "") buttonsUsed = storedButtons;

			var storedMode = CustomSettingsApi.getString("hud_prompt_mode", "auto");
			if (storedMode != null && storedMode != "") {
				if (storedMode == "default") {
					promptMode = "auto";
				} else if (storedMode == "kbm_dark" || storedMode == "kbm_light" || storedMode == "positional" || storedMode == "arrows") {
					keyboardStyle = storedMode == "kbm_light" ? "kbm_light" : "kbm_dark";
					promptMode = "kbm";
				} else {
					promptMode = storedMode;
				}
			}

			var storedStyle = CustomSettingsApi.getString("hud_controller_style", "auto");
			if (storedStyle != null && storedStyle != "") {
				if (storedStyle == "positional" || storedStyle == "arrows" || storedStyle == "kbm_dark" || storedStyle == "kbm_light") {
					keyboardStyle = storedStyle == "kbm_light" ? "kbm_light" : "kbm_dark";
					controllerStyle = "auto";
				} else if (storedStyle.indexOf("steam_") == 0 || storedStyle == "oculus" || storedStyle == "vive") {
					controllerStyle = "auto";
				} else {
					controllerStyle = storedStyle;
				}
			}

			var storedKbm = CustomSettingsApi.getString("hud_keyboard_style", "text");
			if (storedKbm != null && storedKbm != "") {
				if (storedKbm == "positional" || storedKbm == "arrows") storedKbm = "kbm_dark";
				keyboardStyle = storedKbm;
			}

			settingsRegistered = true;
			if (context != null) {
				context.log("HUD Input Selector registered settings directly with CustomSettingsApi.");
			}
			applyGlyphPreference();
			syncHUD(true);
			return true;
		} catch (e:Dynamic) {
			if (context != null) {
				context.log("Direct CustomSettingsApi call threw (" + Std.string(e) + "), attempting bridge fallback...");
			}
		}

		// 2. Dynamic bridge fallback through facade.customSettingsApi
		var bridge:Dynamic = Reflect.field(facade, "customSettingsApi");
		if (bridge == null) bridge = Reflect.field(facade, "settingsExtender");
		if (bridge == null) return false;

		try {
			var addCat = Reflect.field(bridge, "addCategory");
			if (addCat != null) {
				Reflect.callMethod(bridge, addCat, ["input_hud", "INPUT HUD", "hud_input_selector"]);
			}

			var addChoice = Reflect.field(bridge, "addSimpleChoice");
			if (addChoice != null) {
				Reflect.callMethod(bridge, addChoice, [
					"input_hud",
					"hud_buttons_used",
					"BUTTONS USED",
					"Selects which key binding from game controls to display on the HUD: Default (primary) or Alt (secondary).",
					["default", "alt"],
					["Default", "Alt"],
					"default",
					function(val:Dynamic) {
						var s = Std.string(val);
						if (s != buttonsUsed) {
							buttonsUsed = s;
							syncHUD(true);
						}
					}
				]);

				Reflect.callMethod(bridge, addChoice, [
					"input_hud",
					"hud_prompt_mode",
					"BUTTON PROMPTS",
					"HUD prompt style: Auto Detect (switches dynamically between controller and keyboard), Keyboard, or Controller.",
					["auto", "kbm", "controller"],
					["Auto Detect", "Keyboard", "Controller"],
					"auto",
					function(val:Dynamic) {
						var s = Std.string(val);
						if (s != promptMode) {
							promptMode = s;
							applyGlyphPreference();
							syncHUD(true);
						}
					}
				]);

				Reflect.callMethod(bridge, addChoice, [
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
					"auto",
					function(val:Dynamic) {
						var s = Std.string(val);
						if (s != controllerStyle) {
							controllerStyle = s;
							applyGlyphPreference();
							syncHUD(true);
						}
					}
				]);

				Reflect.callMethod(bridge, addChoice, [
					"input_hud",
					"hud_keyboard_style",
					"KEYBOARD STYLE",
					"Visual style used when keyboard prompts are active: Text (labels), Dark Keys, or Light Keys.",
					["text", "kbm_dark", "kbm_light"],
					["Text", "Dark Keys", "Light Keys"],
					"text",
					function(val:Dynamic) {
						var s = Std.string(val);
						if (s != keyboardStyle) {
							keyboardStyle = s;
							applyGlyphPreference();
							syncHUD(true);
						}
					}
				]);
			}

			var getStr = Reflect.field(bridge, "getString");
			if (getStr != null) {
				var storedButtons = Reflect.callMethod(bridge, getStr, ["hud_buttons_used", "default"]);
				if (storedButtons != null && storedButtons != "") buttonsUsed = storedButtons;

				var storedMode = Reflect.callMethod(bridge, getStr, ["hud_prompt_mode", "auto"]);
				if (storedMode != null && storedMode != "") {
					if (storedMode == "default") {
						promptMode = "auto";
					} else if (storedMode == "kbm_dark" || storedMode == "kbm_light" || storedMode == "positional" || storedMode == "arrows") {
						keyboardStyle = storedMode == "kbm_light" ? "kbm_light" : "kbm_dark";
						promptMode = "kbm";
					} else {
						promptMode = storedMode;
					}
				}

				var storedStyle = Reflect.callMethod(bridge, getStr, ["hud_controller_style", "auto"]);
				if (storedStyle != null && storedStyle != "") {
					if (storedStyle == "positional" || storedStyle == "arrows" || storedStyle == "kbm_dark" || storedStyle == "kbm_light") {
						keyboardStyle = storedStyle == "kbm_light" ? "kbm_light" : "kbm_dark";
						controllerStyle = "auto";
					} else if (storedStyle.indexOf("steam_") == 0 || storedStyle == "oculus" || storedStyle == "vive") {
						controllerStyle = "auto";
					} else {
						controllerStyle = storedStyle;
					}
				}

				var storedKbm = Reflect.callMethod(bridge, getStr, ["hud_keyboard_style", "text"]);
				if (storedKbm != null && storedKbm != "") {
					if (storedKbm == "positional" || storedKbm == "arrows") storedKbm = "kbm_dark";
					keyboardStyle = storedKbm;
				}
			}

			settingsRegistered = true;
			if (context != null) {
				context.log("HUD Input Selector registered settings via facade bridge.");
			}
			applyGlyphPreference();
			syncHUD(true);
			return true;
		} catch (e:Dynamic) {
			if (context != null) context.log("Error registering via bridge: " + Std.string(e));
			return false;
		}
	}

	function ensureCustomLocalGlyphs():Void {
		if (facade == null) return;
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
			var setFn = function(k:String, v:Dynamic) {
				for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
					try {
						var cls:Dynamic = Type.resolveClass(clsName);
						if (cls != null) {
							var fn:Dynamic = Reflect.field(cls, "setIn");
							if (fn != null) {
								Reflect.callMethod(cls, fn, [dict, k, v]);
								return;
							}
						}
					} catch (e:Dynamic) {}
				}
				try {
					dict.set(k, v);
				} catch (e:Dynamic) {}
			};
			var getFn = function(k:String):Dynamic {
				for (clsName in ["ASDictionary", "_ASDictionary.ASDictionary_Impl_", "ASDictionary_Impl_"]) {
					try {
						var cls:Dynamic = Type.resolveClass(clsName);
						if (cls != null) {
							var fn:Dynamic = Reflect.field(cls, "getString");
							if (fn != null) {
								var res:Dynamic = Reflect.callMethod(cls, fn, [dict, k]);
								if (res != null && res != "") return res;
							}
							var fnGet:Dynamic = Reflect.field(cls, "getIn");
							if (fnGet != null) {
								var res:Dynamic = Reflect.callMethod(cls, fnGet, [dict, k]);
								if (res != null && res != "") return res;
							}
						}
					} catch (e:Dynamic) {}
				}
				try {
					return dict.get(k);
				} catch (e:Dynamic) {}
				return null;
			};

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
				var targetVal = getFn(targetKey);
				if (targetVal != null && getFn(aliasKey) == null) {
					setFn(aliasKey, targetVal);
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
				if (ctrl == "View") list.push("XboxSeriesX_View");
				list.push("XboxSeriesX_" + ctrl);
			case "Xbox One":
				if (ctrl == "Menu") list.push("XboxOne_Menu");
				if (ctrl == "View") list.push("XboxOne_Windows");
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
				if (ctrl == "View") list.push("SteamDeck_Inventory");
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
