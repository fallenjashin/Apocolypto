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
| Left click | Stun prod (6 charges, they recharge on the roof) |
| Hold E | Grab and carry |
| Esc | Free the mouse (click to recapture) |

## The rules being tested

- **Prod:** a stun lasts 6s for a Skitter, 9s for a Brute, and 3.5s for a Glimmer.
- **Carrying is a spring from your hands.** Each holder can pull with 1000 N.
  An *awake* specimen struggles harder than one person can hold (1300 to 1700 N), so it breaks free.
  Two people out-pull it. That co-op rule comes from the physics, not a scripted check.
- **Weight slows you down.** You can drag a Brute (70 kg) alone, but it's slow. With two people it's much faster.
- **Depth = value.** Depth 1 has Skitters ($40), Depth 2 has Brutes ($150), Depth 3 has Glimmers ($350, fast, with a short stun).
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
| `scripts/level.gd` | Builds the building, roof camp, burning city and crater in code |
| `scripts/hud.gd` | Menu and HUD |
| `scripts/intro.gd` | The asteroid-impact opening |

**Networking model:** each player owns their own movement. The host owns every specimen's physics and decides every stun and grab.
Clients send requests and the host validates them (for example, it checks that you're close enough).

## Tests

```
./tests/run_tests.sh /path/to/godot
```
- `--selftest`: population spawns on the right floors, a stunned specimen stays held, an awake one escapes one holder,
  two holders can hold it, and the pen pays out and deletes the object.
- `--autotest-host` + `--autotest-join`: two real processes over the network. The client stuns and grabs, the host sees it,
  the delivery happens, and the client's ledger updates.

## Not in yet (next steps, in order)

1. **Playtest with a friend** and tune the struggle and stun numbers until carrying is funny and tense.
2. Steam lobbies and invites (GodotSteam) instead of IP + port.
3. Proximity voice chat.
4. A day timer, the quota deadline, and the contract/price board.
5. The infestation climbing the floors, and the rooftop last stand.
6. Real art, only after 1 feels good.
