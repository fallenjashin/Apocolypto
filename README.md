# Rooftop (working title): Prototype 1, capture & haul

An asteroid hit the city during dinner. Aliens are taking the building floor by floor.
The military pays for **live specimens**. Stun them, grab them, and haul them up to the pen on the roof.

This prototype answers one question: **is dragging a struggling alien up a building with a friend fun?**
Everything is gray boxes on purpose. Don't add art until that answer is yes.

## Run it

1. Open Godot 4.7, **Import**, pick `project.godot`, then press **F5**.
2. To test two players on one PC: **Debug > Customize Run Instances > Enable Multiple Instances**, set it to **2**, and press F5.
   Click **Host** in one window and **Join** in the other.
3. To play with a friend on another network for now, the host forwards **UDP port 7777** and the friend types the host's public IP.
   Steam lobbies replace this later.

## Controls

| Input | Action |
|---|---|
| WASD / Shift / Space | Move / sprint / jump |
| Left click | Stun prod (6 charges, more with Prod Batteries; they recharge on the roof) |
| Hold right click | Grab and carry |
| Esc | Free the mouse (click to recapture) |
| B | Open the military store (on the roof only) |
| E | Use the panel inside an elevator (pick a floor, close/open the doors) |
| R | Host only: start a new run after winning or losing |

## The run

A run is **4 days**. Each day has a **5-minute clock** and a **quota** you must earn before it hits zero.

| Day | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| Quota | $300 | $500 | $750 | $1,000 |

- **Earned today** counts toward the quota and resets every day. The **bank** keeps everything you've ever earned (it's what the store spends).
  Earn more than the quota and the surplus stays in the bank.
- Miss the quota by even $1 when the clock hits zero and the run ends: **OVERRUN**.
- Make it and you get a **day summary** (12 seconds), then the next day starts: the floors close and the crew is back on the roof with full prods.
- Make the day 4 quota and you **win**. The host presses **R** to start a fresh run.
- The host's computer owns the clock; everyone else counts down locally and is corrected twice a second.
- Day 1 starts with a 16-second wait so the opening cinematic can play. Later days start after 6 seconds.
- All the numbers (`QUOTAS`, `DAY_SECONDS`, and so on) are at the top of `scripts/game.gd`. They're a first guess. Tune them after playtests.

## The military store

Press **B** on the roof to open it. Purchases come out of the shared bank (never out of "earned today", so shopping can't make you miss a quota).
Upgrades are crew-wide and last the whole run. The host validates every purchase: you must be on the roof, the run must be live, and the bank must cover it.

| Item | Effect | Price per level |
|---|---|---|
| Prod Battery (3) | +2 prod charges | $120 / $220 / $350 |
| Stun Coils (3) | Stuns last 30% longer | $150 / $250 / $400 |
| Carry Harness (2) | Heavy loads slow you down much less | $180 / $320 |
| Sprint Boots (2) | Sprint 12% faster | $100 / $200 |
| Floodlights | +45 s on today's clock, twice a day | $120 each |

Prices and strengths live in `scripts/shop.gd`. They're a first guess. Tune them after playtests.

## Specimen tempers

Each species has a temper that changes what the crew has to do. The crosshair readout names it and shows a one-line hint.

| Species | Temper | Rule | Team tactic |
|---|---|---|---|
| Skitter | Skittish | One player can walk right up (flees inside 4.5 m). Two or more nearby and it flees from 8 m, 40% faster. | Approach one at a time; the rest hang back |
| Brute | Territorial | Never flees. Once stunned, it hunts whoever stunned it for 10 s, faster than it walks but slower than your walk, and shoves them on contact (drops what they carry). | The stunner leads it away while someone else grabs |
| Glimmer | Shy | Faster than a sprint (10 vs 8). **Blinks:** when a player gets within 9 m it flickers for 0.25 s, then teleports to a spot at least 10 m from everyone (5 s cooldown). A stun during the flicker cancels it. Freezes solid only while 2+ players have it near the middle of their view (within 16 m), and a frozen Glimmer can't blink. **Volatile:** when its stun wears off it has a 3 s fuse, and if nobody stuns it again it explodes. The loot is lost and everyone within 7 m is thrown back and drops what they carry. | Two people stare to pin it, one closes in. Keep a prod charge ready for the re-stun |

Fleeing specimens look for open space ahead, so they can't be pinned against walls or run off roof edges and down holes.
Specimens that get dropped away from their spawn spot walk back to it along the maze route (breadth-first search on the maze grid).

Tells: a hunting Brute pulses red ("ENRAGED!") a frozen Glimmer glows white ("FROZEN"), and a Glimmer on its fuse blinks faster and faster ("UNSTABLE"). Looks ignore walls for now.
Numbers are at the top of `scripts/specimen.gd`. They're a first guess. Tune them after playtests.

## The elevator and the floors

The roof has an elevator (the grey box). Step inside and press **E**: pick a floor, or close/open the doors.
Everyone standing in the cab rides together, **and so does any loot in there with them**. That is how you bring catches up to the roof pen.

- Only one floor exists at a time, and it is nowhere near what the building looks like from outside. It is a **maze of 6 m cells** grown from a seed, so every peer builds the same one without sending the layout.
- Floors are data. Floors 10, 9 and 8 are your design (75/20/5, 30/50/20, 30/30/40 skitter/brute/glimmer). Floors 7 and 6 are my extrapolation.
- Leaving a floor closes it: whatever you left behind is gone. A new descent grows a fresh maze with a fresh set of specimens.
- The elevator only runs while the day's clock is running, and a floor can only be opened while nobody is on a different one.
- Every cell of every floor is reachable from the elevator (tested over 100 mazes).

## The rules being tested

- **Prod:** a stun lasts 6s for a Skitter, 9s for a Brute, and 3.5s for a Glimmer.
- **Carrying is a spring from your hands.** Each holder can pull with 1000 N.
  An *awake* specimen struggles harder than one person can hold (1300 to 1700 N), so it breaks free.
  Two people out-pull it. That co-op rule comes from the physics, not a scripted check.
- **Weight slows you down.** You can drag a Brute (70 kg) alone, but it's slow. With two people it's much faster.
- **Deeper floors pay more.** Each floor is data (`Floors.LIST` in `scripts/floors.gd`): its maze size, how many specimens it holds and what mix of species.
- **Loot becomes data.** When a specimen reaches the pen, the physics object is deleted and becomes a ledger entry.
  Nothing piles up, so there's no Lethal Company-style loot lag or disappearing items.

All the numbers are at the top of `scripts/specimen.gd`, `scripts/player.gd` and `scripts/game.gd`. Tune them freely.

## Opening cinematic

You load in at the northeast railing of the roof, facing the city. An asteroid streaks down and hits: white-out flash,
boom, screen shake, debris, and the crater's green light column. A giant rises out of the crater and roars,
then a pack of aliens pours out, runs across the streets and climbs into the floors of your building.
It takes about 16 seconds, plays locally for each player, and you can move the whole time.
The sounds are generated in code (no audio files yet). Timing is at the top of `scripts/intro.gd`.

## The roof and the city

- The roof deck is 36 x 36 m (the building below is 30 x 30), with a see-through railing.
  **Small specimens can slip under the railing,** so don't drop your catch off the roof.
- The city sits on a street grid: sidewalks, road lines, wrecked and burning cars, and a scorched, rubble-strewn impact site.

## Files

| File | What it does |
|---|---|
| `scripts/game.gd` | Host/join, spawning, server-side stun/grab requests, the pen and ledger, test modes |
| `scripts/player.gd` | First-person movement, prod, grab, aim assist |
| `scripts/specimen.gd` | Species table, struggle physics, flee/wander AI (server only) |
| `scripts/level.gd` | Builds the roof camp, the building's outer shell, the burning city and the crater in code |
| `scripts/floors.gd` | Floor data (species mixes), seeded mazes, maze pathfinding, the elevator cab |
| `scripts/hud.gd` | Menu and HUD |
| `scripts/intro.gd` | The asteroid-impact opening |

**Networking model:** each player owns their own movement. The host owns every specimen's physics and decides every stun and grab.
Clients send requests and the host validates them (for example, it checks that you're close enough).

## Tests

```
./tests/run_tests.sh /path/to/godot
```
- `--selftest`: floor mixes add up, mazes are connected and identical for a given seed, the elevator carries the crew and loot,
  a stunned specimen stays held, a stunned specimen stays held, an awake one escapes one holder,
  two holders can hold it, and the pen pays out and deletes the object.
- `--autotest-host` + `--autotest-join`: two real processes over the network. The client stuns and grabs, the host sees it,
  the delivery happens, and the client's ledger updates.

## Not in yet (next steps, in order)

1. Steam lobbies and invites (GodotSteam) instead of IP + port.
2. Proximity voice chat.
3. The infestation climbing the floors, and the rooftop last stand.
4. Real art, only after the rest feels good.
