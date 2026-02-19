# ABC Reminder - Always Be Casting

## Overview
ABC Reminder is a World of Warcraft addon that helps you maintain optimal DPS by reminding you to **always be casting**. When you're in combat within an instance but not actively casting a spell, the addon will play an audio alert to prompt you to get back to casting.

## Installation
1. Download or clone the addon files.
2. Extract the contents into your World of Warcraft `Interface/AddOns` directory.
3. Reload your UI or restart WoW for the addon to load.

## Usage
The addon activates automatically when you enter combat in a supported instance (raids, dungeons, scenarios, etc.). If you're standing idle without casting while the Global Cooldown is ready, you'll hear a water drop sound reminder.

## Features
- **Combat-aware reminders**: Only alerts you when actually in combat in instances
- **Configurable instance types**: Choose which instance types trigger reminders (raids, dungeons, scenarios, arenas, etc.)
- **Smart cooldown detection**: Won't alert you if the Global Cooldown is still active
- **Customizable sound**: Configure which sound file and audio channel to use
- **Adjustable reminder frequency**: Set how often you want to be reminded while idle
- **Instance filtering**: Enable/disable reminders for different instance types
- **Combat statistics**: Tracks total combat time and number of reminders played

## Configuration
The addon saves settings in `ABCReminderDB`. You can modify:
- **enabled**: Turn the addon on/off
- **soundInterval**: Frequency of reminders (in seconds)
- **soundFile**: Path to the sound file
- **soundChannel**: Audio channel (Master, SFX, Music, Ambience, Dialog)
- **enabledInstances**: Toggle reminders for specific instance types

## Contributing
Feel free to fork the repository and submit a pull request with improvements.

## License
This addon is licensed under the MIT License. See the LICENSE file for more details.