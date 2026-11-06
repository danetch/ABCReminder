# ABCReminder

A World of Warcraft addon that helps players optimize their DPS by tracking idle time ("Always Be Casting") and reminding them to keep casting.

## 🎯 Purpose

ABCReminder tracks how much time you spend idle (not casting, channeling or on the global cooldown) during combat and plays a sound when you are idle. It helps eliminate DPS lost to dead time and shows you how you did after each pull.

## ✨ Key Features

### 1. Real-Time Idle Detection
- **Smart detection** of casting, channeling and the global cooldown
- **Time spent dead is ignored**, so a death doesn't wreck your uptime
- **Whole boss fights**: a boss pull is measured from `ENCOUNTER_START` to `ENCOUNTER_END`, even if you drop out of combat in between (death, phase transition)

### 2. Audio Reminders
- **Sound alerts** play while you're idle and could be casting
- **Adjustable frequency**: 1–10 seconds between reminders
- **Clipping**: the sound stops as soon as you start casting again
- **Two sounds**: "WaterDrop" or "SharpPunch"
- **Audio channel**: Master, SFX, Music or Ambience

### 3. Result Card After Each Pull
- **Active %**, compared with your previous kill of the same boss / run of the same dungeon
- **Combat time and idle time**
- **Idle gaps**: how many times you stayed idle for more than 1 second, and the longest gap
- **Why you were idle**: idle time split into *moving* (running, falling), *CC* (stunned, feared, polymorphed, silenced, interrupted; disarmed for weapon specs — roots don't count) and *standing still* — the part you can actually fix
- **Personal best**, with a fanfare when you beat it (no fanfare for a first kill)
- **Wipes** are shown too (greyed), but never count as records

### 4. Statistics & History
- **Raid bosses**: per boss and difficulty — kills, wipes, last kill, best, average and the last 10 attempts
- **Mythic+**: per dungeon — key level, timed / over time / abandoned, boss breakdown and the last 10 runs
- **Raids**: only boss encounters are measured; raid trash is ignored
- **Trash & other content** (dungeons, scenarios, …): session stats (last pull + session average), reset when you enter an instance
- **History window** (`/ar history`): Raid and Mythic+ tabs, difficulty filter (works on any client language), hover a row for recent attempts
- **Minimum raid boss duration** filter to skip trivial old content

### 5. Instance Filtering
Choose where statistics are tracked and reminders play:
- **Party** dungeons, **Raids**, **Scenarios** (on by default)
- **Arenas**, **PvP**, **Open World** (off by default)

Each specialization can also be turned off individually.

## 📥 Installation

1. Download and extract the `ABCReminder` folder
2. Place it in `World of Warcraft\_retail_\Interface\AddOns\` (keep the `sound/` and `img/` folders)
3. Restart World of Warcraft or type `/reload`
4. Configure in **Options → AddOns → ABCReminder**, or type `/ar`

## ⌨️ Commands

| Command | Action |
|---|---|
| `/ar` | Open the options |
| `/ar history` (or `/ar stats`) | History window |
| `/ar raid`, `/ar mythic` | History on the Raid / Mythic+ tab |
| `/ar session` | Show the current session stats |
| `/ar reset session` | Reset session stats |

The addon compartment button (minimap menu): left-click toggles the addon for this character, right-click opens quick actions.

## ⚙️ Settings Panel

- **General**: enable for this character; where to track and remind (instance types)
- **Specializations**: turn the addon off for specific specs
- **Sound**: interval, stop on cast, channel, sound file, test button
- **Statistics**: result window fade-out delay (0 = stays open), where to show session results (floating window, general chat or a dedicated chat tab), record wipes and abandoned keys, minimum raid boss duration, reset all statistics

## 💾 Data Storage

- **ABCReminderDB**: account-wide settings (window positions, sound settings, display options)
- **CharABCRDB**: per-character data (enable status, disabled specs, boss and dungeon records, session stats)

Statistics recorded by older versions are kept and keep working with the new history window.

## 🎵 Sounds

- `sound/WaterDrop.ogg` — gentle water drop
- `sound/SharpPunch.ogg` — sharp punch

The personal-record fanfare uses WoW's built-in sound kit 888.

## 🔄 Game Version Updates

A GitHub Actions workflow (`.github/workflows/bump-toc.yml`) checks Blizzard's patch server every day. When a new retail version goes live, it adds the matching interface number to `## Interface:` in `ABCReminder.toc` and commits it to `main`. It can also be run by hand from the repository's **Actions** tab.

## 📊 Performance Impact

- Event-based; per-frame work only while in combat
- Sound checks every 0.1 seconds during combat only
