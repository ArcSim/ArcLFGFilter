# Arc LFG Filter changelog

## 1.3.1

### Bug Fixes
- **The filter tab fills its tab** - The eye sat small in the middle of the fourth tab with dark around it. It is drawn at the size the window gives its own tab icons now, so it runs to the frame like the three above it.

## 1.3.0

### New Features
- **The filter is a panel now** - Every option sits in a panel attached to the side of the Looking For Group window, in the game's own panel art, instead of a menu you have to hold open, with a tab for player rules, a tab for group rules and a tab for invites. The count sits along the bottom. The funnel button opens and shuts it, a fourth tab on the window's own tab strip does too, and right-clicking the funnel still opens the old menu.
- **Only ones near me** - One tick keeps the players standing in your zone, the groups whose leader is, and anyone already at the dungeon they listed for, so you stop inviting people who are a continent away.
- **Roles per class** - Every class has its own line with its own Tank, Healer and DPS buttons: tank and damage warriors is two clicks on the warrior line. A class with nothing picked still means any role, and asking for a role ticks the class with it.
- **Groups that must have a class** - The group class list answers three ways now. Click once and only groups holding that class are shown, which is how you find a group that already has a warlock to summon you; click again to hide every group with one; click again for any.
- **Set what you are without leaving the window** - The Groups tab has your own Tank, Healer and DPS buttons. They are your real listing's roles, so "Has a spot for me" follows them straight away.
- **Invite someone as a role** - The invite whisper says what you are inviting them for: "Inviting you to run Deadmines as Tank" is the line it ships with now. Someone who listed one role gets it by itself, and when they listed several the invite asks which one you want first, from the list and from the whisper queue alike. Write your own line on the Invites tab; an invite message you had already written is left exactly as it was.
- **Quick messages, your way** - Mark which one fills the Send Message box, write {level}, {class} and {role} and they fill themselves in, and a line you tweak before sending is kept for next time. All three lines are editable in the Invites tab.
- **Suggest invite** - In someone else's group, where the game will not let you invite, the invite button becomes Suggest and asks your group leader to invite the player, exactly like the game's own Suggest Invite. It greys out when the group is already full.

### Improvements
- **Where everyone is** - Each listing shows the zone the player is standing in, or the leader's zone for a group, next to the dungeon. Your own zone is green, so anyone nearby stands out.
- **Your filter is remembered** - It comes back after a reload and after logging out, instead of starting empty every session.
- **The list is ready when you open the window** - The addon's list is in place as soon as you start looking, filter or no filter.
- **Every class, always** - The class list holds all nine with how many are in the results right now, so it never reflows while you are reading it.
- **The menu stops jumping** - Ticking a filter in the old menu no longer resizes it under your cursor.

### Bug Fixes
- **Listings behind the buttons** - The last row of the list could sit behind Send Message and Group Invite.
- **A class you unticked could still filter** - Roles picked from a class kept filtering after the class itself was off, with nothing on screen to say so. Clearing a class, or Any class, now clears its roles with it.

## 1.2.0

### New Features
- **Whisper queue** - While your group is listed, everyone who whispers you lands in a Whispers section at the top of the list, next to Players and Groups and collapsible the same way: their class, level, the roles they signed up as, where they are and what they wrote, with Invite and Reply on every line. Someone standing in your own zone is marked "here". Turn it on with Whisper queue in the filter menu.
- **Quick messages** - The Send Message box has ready-made lines to click. The first one says "Level 20 Mage here, can I join?" with your own level and class filled in. Write your own under /arclfg.
- **Find groups by the roles they still need** - Open spot for: pick Tank, Healer or DPS and only groups with a free slot for one of them are shown, whichever role you are queued as.
- **Find groups by who they already have** - Already has: pick the roles a group must already include, for example only groups that have found a tank.

### Improvements
- **Role and class icons in the menu** - Tank, Healer and DPS entries now show the game's role icons, and every class in both class lists shows its class icon.

### Bug Fixes
- **Buttons behind the list** - Send Message and Group Invite could end up behind the filtered list at the bottom of the window.

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
