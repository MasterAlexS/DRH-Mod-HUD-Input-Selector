# HUD Input Selector

A mod for [Dungeon Rampage Haxe](https://github.com/Tutez64/Dungeon-Rampage-Haxe) that gives you full control over in-game HUD button prompts, key bindings display, and controller icon styles.

<!-- drh:show -->
### Settings & Organization
- **Standalone**: Works out of the box with native settings on Mod API 1.4.0+.
- **Recommended**: **[Custom Settings API](https://github.com/MasterAlexS/DRH-Mod-Custom-Settings-API)** — provides a dedicated, beautifully organized **INPUT HUD** menu tab and category in the settings.

---

### Features

Take control of how button prompts are displayed across the entire in-game HUD:

1. **BUTTONS USED**:
   - **Default**: Displays the primary key bindings configured in the game controls.
   - **Alt**: Displays the secondary / alternate key bindings configured in the game controls.

2. **BUTTON PROMPTS**:
   - **Auto Detect**: Dynamically switches HUD prompts based on the last active input device (keyboard/mouse vs. controller buttons or analog stick movement).
   - **Keyboard**: Forces keyboard prompts on the HUD at all times.
   - **Controller**: Forces controller prompts on the HUD at all times.

3. **CONTROLLER STYLE**:
   - **Auto Detect**: Uses the game's detected controller icon style.
   - **Console Styles**: DualSense, DualShock 4, Xbox Series/One, Xbox 360, Nintendo Switch, Steam Deck, DualShock 3, Xbox One, Steam Controller, Wii U, Wii, PS Vita, PS Move, Google Stadia, Amazon Luna, Ouya.

4. **KEYBOARD STYLE**:
   - **Text**: Standard text labels matching your configured keys.
   - **Dark Keys**: Graphical keycap prompts on a dark background.
   - **Light Keys**: Graphical keycap prompts on a light background.

5. **FULL HUD PROMPT COVERAGE**:
   - **Action Bar & Potions**: All skill slots, health potion, and hero abilities display styled keycaps or controller glyphs.
   - **Top-Right Buttons**: Displays ESC and O keycaps for Keyboard (Dark/Light keys), or Menu (Start/Options) and View (Back/Select/Touchpad) glyphs for Gamepads on Close [X] and Settings Gear buttons.
   - **Chat Log**: Displays the controller D-Pad Left prompt icon on the chat `LOG` button.
   - **Ultimate / Buster**: Formats prompts with `"PRESS [GLYPH]"` for Controller and Dark/Light keycaps, and `"PRESS B"` in text mode.

### Floor Transitions & Persistence
- HUD button prompts persist seamlessly between dungeon floors, gate transitions, and respawns without reverting or disappearing.
- Settings are saved automatically per mod across game restarts.
<!-- /drh:show -->
