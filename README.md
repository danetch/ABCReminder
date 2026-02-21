# ABCReminder

A World of Warcraft addon that helps players optimize their DPS by tracking idle time and providing visual/audio reminders of available casting windows.

## 🎯 Purpose

ABCReminder tracks how much time you spend idle (not casting/channeling) during combat encounters and reminds you to keep casting. It helps eliminate loss of DPS from dead time and ensures you are always casting something.

## ✨ Key Features

### 1. Real-Time Idle Detection
- **Smart detection** of casting, channeling, and ability cooldowns
- **Continuous monitoring** during combat with minimal performance impact
- **Automatic combatant tracking** - starts when you enter combat, ends when combat ends

### 2. Spell Queue Window (SQW) Visual
- **Green circle indicator** shows when you're within the spell queue window
- **Gray circle mode** optionally displays the indicator even outside the SQW during combat (grayed out)
- **Draggable UI** - reposition the circle anywhere on screen by clicking and dragging
- **Configurable display** - toggle on/off as needed

### 3. Audio Reminders
- **Smart sound alerts** play when you're idle and eligible to cast (based on current encounter type)
- **Adjustable frequency** - set intervals from 1-10 seconds between sound reminders
- **Manual clipping** - automatically stops sounds if you resume casting
- **Multiple sound options**: "WaterDrop" or "SharpPunch" effects
- **Audio channel selection** - output to Master, SFX, Music, or Ambience channel

### 4. Performance Statistics
- **Boss encounters** (Raid/Mythic+): Persistent records tracked with:
  - Current run idle percentage
  - Personal best (lowest) idle percentage
  - Total time and idle time counters
  - Automatic record notifications when you beat your best
- **Trivial content**: Session-based stats with reset option
- **Auto-hiding** statistics windows after configurable duration
- **History browser** - navigate your previous boss encounters with arrow buttons

### 5. Flexible Instance Filtering
- Enable/disable tracking for specific encounter types:
  - **Party** dungeons
  - **Raids** (with persistent record-keeping)
  - **Scenarios**
  - **Arenas** (disabled by default)
  - **PvP** (disabled by default)
  - **Open World** (disabled by default)

## 📥 Installation

1. Download and extract the `ABCReminder` folder
2. Place it in `World of Warcraft\_retail_\Interface\AddOns\`
3. Restart World of Warcraft or type `/reload`
4. Configure in: **Interface → Addons → ABCReminder**

## 🎮 How It Works

### During Combat
1. Addon automatically detects when you enter combat
2. Tracks idle time and casting/channeling activity in real-time
3. Plays audio reminders when you're eligible to cast (if enabled for that instance type)
4. Shows SQW visual to indicate optimal casting windows
5. On combat end, displays your performance stats

### Statistics Display
- **Raid/Mythic+ fights**: Persisted to character data; navigate with `<` and `>` buttons; personal best achievements trigger fanfare
- **Trivial encounters**: Session-only stats; click "Reset Session" button to clear cumulative data
- Stats automatically hide after duration expires (0 = stays visible)

## ⚙️ Settings Panel

### General
- **Enable for this character**: Toggle the addon on/off
- **Instance type checkboxes**: Choose which encounter types to track

### Audio Settings
- **Sound Interval** (1-10 seconds): How often reminders trigger while idle
- **Stop sound when casting resumes**: Auto-clips sounds if you start casting
- **Sound Channel**: Select output channel (Master, SFX, Music, Ambience)
- **Sound File**: Choose between sound effects
- **Test Sound**: Preview the selected audio file

### Visual Settings
- **Show Spell Queue Window visual**: Toggle the circular SQW indicator
- **Always show (in combat - Grayed)**: Display indicator during combat even when outside SQW window
- **Reset SQW Position**: Return indicator to center of screen
- **Stats display duration**: How long statistics remain visible (0 = permanent; 5-30 seconds recommended)

## 💾 Data Storage

- **ABCReminderDB**: Account-wide configuration (positions, sound settings, intervals)
- **CharABCRDB**: Character-specific data (enable status, boss records, session stats)
- All data automatically persists between game sessions

## 🎵 Sound Files

The addon includes two audio options located in the `sound/` folder:
- `WaterDrop.ogg` - Gentle water drop sound
- `SharpPunch.ogg` - Sharp punch/hit sound

Victory fanfare uses WoW's built-in "Trumpet" sound (ID: 12123)

## 📊 Performance Impact

- **Minimal overhead**: Uses event-based architecture with efficient updates
- **OnUpdate checks** every 0.1 seconds during combat only
- **Optimized calculations** for spell cooldowns and cast tracking

    Place the ABCReminder folder into your World of Warcraft/_retail_/Interface/AddOns/ directory.

    Ensure the sound/ and img/ folders are present within the addon directory.

    Restart World of Warcraft.

Current Status: Development in progress.