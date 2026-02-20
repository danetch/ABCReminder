ABCReminder

ABCReminder is a World of Warcraft optimization tool designed to help players maximize their uptime (Always Be Casting) and perfect their Spell Queue Window (SQW) management.
🚀 Key Features
1. Activity Reminder (Always Be Casting)

    Smart Detection: Monitors in real-time if you are currently casting, channeling, or if the Global Cooldown (GCD) is active.

    Audio Alerts: If you are idle during combat, a sound triggers at regular intervals to remind you to use a capability.

    Customizable Interval: Adjust the sound frequency from 0.5s to 5.0s via the options menu.

    Sound Clipping: Automatically stops the reminder sound as soon as you start a cast, preventing unnecessary noise.

2. Spell Queue Window (SQW) Visual

    Timing Assistance: A segmented circular UI element indicates exactly when the game engine will accept your next spell input.

    Countdown Logic: The circle appears full at the start of the SQW and loses segments as time runs out.

    Adaptive Segments: Automatically calculates the number of segments based on your system SpellQueueWindow setting (1 segment per 100ms).

    "Always Show" Mode: Optional setting to keep the visual visible as a dim gray circle during the entire GCD/Cast, lighting up in bright green only when the input window opens.

3. Performance Tracking & Statistics

    Persistent Records: Automatically saves your best "Idle Time" ratios for Raid Bosses and Mythic+ completions.

    Record Fanfare: Triggers a special sound and a celebratory chat message when you beat your personal activity record on a boss.

    Session Mode (Trivial Content): For Open World or Normal/Heroic dungeons, stats are tracked for the current session only. This allows you to monitor performance without polluting your high-end records.

4. Customization & UI

    Comprehensive Options Panel: Integrated into the standard WoW Interface menu, featuring custom graphics (drops.tga).

    Instance Filtering: Choose exactly where the addon should be active (Raid, Party, Scenarios, or Open World).

    Audio Management: Select your preferred output channel (Master, SFX, Music, or Ambience) and choose between different sound files.

    Movable UI: The SQW visual can be unlocked and repositioned anywhere on your screen.

⌨️ Slash Commands
Command	Description
/ar	Opens the ABCReminder configuration panel.
/ar move	Toggles "Move Mode" for the SQW visual (appears blue when movable).
/ar reset session	Manually resets the current trivial content session statistics.
🛠 Installation

    Download the repository.

    Place the ABCReminder folder into your World of Warcraft/_retail_/Interface/AddOns/ directory.

    Ensure the sound/ and img/ folders are present within the addon directory.

    Restart World of Warcraft.

Current Status: Development in progress. Refining SQW segment transitions and visual feedback.