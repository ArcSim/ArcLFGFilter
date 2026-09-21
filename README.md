# Arc LFG Filter

A filter for the Looking For Group window in **WoW Forever**.

A funnel button next to the refresh button opens the filter menu:

- **Show** - players and groups, players only, or groups only.
- **Players signed up as** - Tank, Healer and/or DPS.
- **Class** - only the classes you pick, combined with the role filter (DPS + Mage = DPS mages). Every class is listed, with counts.
- **Groups: has a spot for me** - only groups with an open slot for the role you are queued as.
- **Groups: hide groups with** - skip any group that has someone of a class you pick (for example no Hunters).
- **Invites: whisper when I invite** - players you invite from the list also get a whisper, "Inviting you to run Deadmines" by default. Write your own under **Edit invite message** (or `/arclfg`): `{dungeon}` becomes the dungeon and `{name}` the player's first name.

Nothing is filtered until you turn something on, and the filter resets each session. The invite whisper stays off until you turn it on; it and your message are the only things saved.

`/arclfg debug` opens a debug log you can copy and share if something looks wrong.

Made by Arc. WoW Forever only.
