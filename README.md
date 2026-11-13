# HUD Input Selector

A mod for [Dungeon Rampage Haxe](https://github.com/Tutez64/Dungeon-Rampage-Haxe) that gives you full control over in-game HUD button prompts, key bindings display, and controller icon styles.

<!-- drh:show -->
### Requirements
- **[Custom Settings API](https://github.com/MasterAlexS/DRH-Mod-Custom-Settings-API)** (required to configure options in-game).

---

### Features

Take control of how button prompts are displayed on your HUD:

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

### Seamless Settings Integration
- Integrated directly into the **INPUT HUD** category of the in-game Settings menu via `CustomSettingsApi`.
- Settings are saved automatically per mod across game restarts.
<!-- /drh:show -->
