# Rooftop: notes for Claude

- Godot 4.7, GDScript, everything built in code (scenes/main.tscn only holds scripts/game.gd).
- Networking: ENet, host is server. Players own their movement; host owns specimen physics and validates stun/grab RPCs on Game.
- Loot-as-data: delivered specimens are freed and become ledger numbers. Never let banked loot exist as physics objects.
- Spawning goes through MultiplayerSpawner with spawn_function (data arrays), never add_child for networked nodes.
- Run ./tests/run_tests.sh <godot> after every change; add a check to --selftest for new rules.
- The owner is learning: explain changes plainly, keep scope to the current prototype phase (see README "Not in yet").
