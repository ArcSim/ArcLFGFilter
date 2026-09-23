# Arc LFG Filter changelog

## 1.1.0

### New Features
- **Filter players by level** - Type a minimum level in the filter menu, for example 18 or 50, to show only players of that level or higher. Works together with the role and class filters.

### Improvements
- **Closing the filter menu** - Click the filter button again to close its menu.

### Bug Fixes
- **Druid missing from the class lists** - Both class lists now always include Druid, even when no druid is listed.
- **Category menu error** - After using the filter menu, picking a category in the Looking For Group window could stop the search with an addon error. The filter menu is now drawn by the addon itself and no longer interferes with the game's own Category and Activity menus.

## 1.0.0

First public release, for WoW Forever.

### New Features
- **Advanced Filter button** - A funnel button next to the refresh button in the Looking For Group window opens the filter menu. It lights up and shows how many listings are left while a filter is on.
- **Filter players by role** - Show only players signed up as Tank, Healer or DPS. Tick more than one to combine them.
- **Filter players by class** - Pick one or more classes, for example only Mages and Warlocks. Works together with the role filter, so DPS plus Mage shows only DPS mages. Every class is listed, with how many players of each are in the results right now.
- **Players only or groups only** - Hide groups while you are recruiting, or hide solo players while you are looking for a group.
- **Groups with a spot for you** - Show only groups that still have an open slot for the role you are queued as.
- **Hide groups with a class** - Skip any group that has someone of a class you pick, for example no groups with a Hunter or a Rogue.
- **Works like the normal list** - While a filter is on you can still click a listing and use Send Message or Group Invite, right-click for both, and hover a group to see every member with their role and level.
- **Invite whisper** - Players you invite from the list can also get a whisper, "Inviting you to run Deadmines" by default. Write your own message under Edit invite message in the menu, or with /arclfg: {dungeon} becomes the dungeon and {name} the player's first name. Off until you turn it on.
- **Reset in one click** - Reset filter clears the filter. Nothing is filtered until you turn something on.

### Good to know
- **When the game hides the list** - WoW Forever stops addons from reading the Looking For Group list at times, for example inside dungeons. The filter then steps aside: the button shows a red "!" and the normal list is shown, so the window keeps working. The invite whisper also stays quiet then.
- **What is saved** - The filter resets each session on purpose. Only the invite whisper switch and your message are saved. WoW Forever currently has a bug that can stop addon settings from loading after the game starts, so if the whisper is off or your message is back to the default, just set it again.
