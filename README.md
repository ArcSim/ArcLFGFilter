# Arc LFG Filter

A filter for the Looking For Group window in **WoW Forever**.

A funnel button next to the refresh button opens the filter panel, attached to the side of the window, with a fourth tab on the window's own tab strip that opens it too. It has a tab for player rules, a tab for group rules and a tab for invites.

**Players**

- **Show** - players and groups, players only, or groups only.
- **Signed up as** - Tank, Healer and/or DPS.
- **Minimum level** - type a level (for example 18 or 50) to see only players of that level or higher.
- **Only ones near me** - keeps the players standing in your zone, the groups whose leader is, and anyone already at the dungeon they listed for.
- **Class** - only the classes you pick, combined with the role filter (DPS + Mage = DPS mages). Every class is always listed, with counts, and each line has its own Tank, Healer and DPS buttons: tick the class, then pick the roles you want from that one class.

**Groups**

- **I am signed up as** - your own roles, the ones the game uses, so you can change them without leaving the window.
- **Has a spot for me** - only groups with an open slot for the role you are queued as.
- **Open spot for** - only groups with an open slot for the roles you pick, whichever roles you are queued as.
- **Already has** - only groups that already have the roles you pick, for example a group that already found a tank.
- **Classes in the group** - one line per class, clicked through: any, only groups that already have one (a warlock to summon, say), or hide every group with one.

**Invites**

- **Whisper queue** - a Whispers section at the top of the list, next to Players and Groups, holding everyone who whispers you while your group is listed, with their class, level, roles and message, and Invite and Reply on every line. Off until you turn it on.
- **Quick messages** - ready-made lines in the Send Message box. Mark the one that fills the box, write `{level}`, `{class}` and `{role}` and they fill themselves in, and a line you tweak before sending is kept for next time.
- **Whisper when I invite** - players you invite from the list also get a whisper, "Inviting you to run Deadmines as Tank" by default. Write your own on the Invites tab: `{dungeon}` becomes the dungeon, `{name}` their first name and `{role}` the role you are inviting them for, which the invite asks about when they signed up as more than one.

Each listing shows the zone the player is in, or the leader's zone for a group, with your own zone in green.

Nothing is filtered until you turn something on, and your filter is remembered across reloads and logins. Right-clicking the funnel opens the old menu instead of the panel. The addon's list is in place as soon as you open the window, filter or no filter. In someone else's group the invite button becomes **Suggest**, the game's own Suggest Invite, so your leader gets the ask. The invite whisper stays off until you turn it on.

`/arclfg debug` opens a debug log you can copy and share if something looks wrong.

Made by Arc. WoW Forever only.
