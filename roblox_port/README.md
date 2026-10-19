# Roblox port kit

This folder has what's needed to rebuild this sandbox in Roblox Studio as close to 1:1 as Roblox allows: the assets
cut to Roblox's limits, every number the game reads, and a prompt (`PROMPT.md`) for a local Claude Code with the Roblox
Studio MCP. The Rust code stays the spec.

## Can it be 1:1?

| Feature | 1:1? | How |
|---|---|---|
| Swing, swing jump, fall, point launch (the game's own code) | **Yes** | `crates/sm_traversal` is plain math with no Bevy in it, so it ports line for line. The pack has the 11 original-game runs and their 1–5 cm tolerances, so the Luau port sits the same test as the Rust one. |
| Ground moves, wall run, forward zip, zip to point, perch, charged jumps, dive | **Yes** | Plain logic in `src/physics.rs`, `zip.rs`, `point_zip.rs`, `jump.rs`, `air.rs`, `traversal.rs`. |
| Collision, swing points, perch ledges | **Yes** | Built from the exact triangles and boxes the Rust build uses (in the pack), not from Roblox physics. |
| 60 Hz fixed step with smooth frames in between | **Yes** | Same accumulator and interpolation, run on Roblox's frame events. |
| Animations: 68 clips, blends, mirrored swings, timing | **Yes, minus bone scale** | Every keyframe is in the pack bit for bit, and Bevy's sampling and blending get reimplemented in Luau. Bone scale is lost (see below). |
| Suit: mesh, 212-bone skin, textures | **Yes** | Same triangles, weights and bones. Three pieces over the 20,000-triangle limit are cut in two, which doesn't show. |
| City: 7 towers, 56 cars, 62 props | **Yes** (optional) | Same meshes and textures, in two import files. Not needed: swinging works on any parts or models you build, as the Rust does with any object it's given. |
| Camera: 5.5 m boom, 93–111° FOV with speed, look-up, wall avoidance | **Yes** | Roblox's FOV is vertical, and Bevy converts it the same way. |
| Webs, zip-point diamond, F3 overlay, HUD | **Yes** (font differs) | Beams and line adornments. Bevy's built-in font isn't in Roblox; a similar monospace font is. |
| Keyboard, mouse, gamepad | **Nearly** | Esc belongs to Roblox's menu, Shift-lock must be turned off, and F12 can't save a file. |
| Look: lighting, shadows, materials | **Close, not 1:1** | Roblox has its own renderer. Textures and material values are the same, but light levels, tonemapping and shadows have to be matched by eye. Fog is linear in both. |

## Not possible in Roblox

1. **Bone scale.** Roblox bones can only move and rotate ([feature request](https://devforum.roblox.com/t/feature-request-bone-scaling-deformation-support/4761420)).
   17 bones scale in the clips: the bicep helpers up to 2.4×, the chest and forearm helpers, the neck up to 15%, and
   the arms and legs up to 9%. The port keeps every joint's position exact by carrying the scale down the chain, but
   the bulge and stretch those bones put in the skin is lost.
2. **Bevy's renderer.** Roblox has no physical light units, no tonemapper choice and no shadow-cascade settings.
3. **F12 screenshot to `screenshots/`**, because Luau can't write files. **Esc to free the mouse** is reserved by Roblox,
   though Roblox's menu frees the mouse anyway.
4. Not impossible, but worth knowing: the Luau numbers won't be bit-identical to the Rust build (64-bit numbers vs
   32-bit). The difference is far below the centimetres the tests allow.

Left out by choice: touch controls, the web build, the smoke tests and `--model-preview`.

## Already done (cloud session)

- `import/SpiderMan.glb`, `import/CityTowers.glb`, `import/CityProps.glb`: every mesh is under 20,000 triangles,
  everything is in studs, and the materials are baked for Roblox. The Khronos glTF validator reports 0 errors. Every
  triangle, normal, UV, joint and weight matches the originals.
- `SpiderManData.rbxmx`: all 68 clips (all 43,248 channels checked bit for bit, in Python and with the Luau decoder
  run in the Luau CLI), 73 collision meshes, the layout, all tuning, the 11 original-game runs and reference poses.
  `FORMAT.md` describes it.
- `manifest.json`: sizes, rest positions and bounds the Studio side checks the import against.
- `tools/build_roblox_pack.py` rebuilds everything (`pip install numpy pillow zstandard`).

Not tested inside Roblox Studio, because there's none in the cloud. The prompt has the local Claude check the import
against `manifest.json` first.

## What you do

1. Pull this branch (`claude/zealous-hopper-o6l4y9`) into your local clone.
2. In Studio, make a new Baseplate place, delete `Baseplate` and `SpawnLocation`, then **File → Save to File**.
3. Connect Claude Code to Studio through the Roblox Studio MCP, if it isn't already.
4. **Import** (Ctrl+M, or File → Import) `roblox_port/import/SpiderMan.glb`. The two city files are optional, since
   swinging works on any map you build yourself. The import dialog can't be driven by the MCP:

   | File | Rig Type | Keep Zero Influence Bones | Scale Unit | Anchored |
   |---|---|---|---|---|
   | `SpiderMan.glb` | Custom | **On** | Studs | (off; Studio decides for rigs) |
   | `CityTowers.glb` | No Rig | – | Studs | On |
   | `CityProps.glb` | No Rig | – | Studs | On |

   Leave **Upload to Roblox** on so the meshes stay in the saved place (they upload privately to your account), and
   leave mesh merging off. Textures can show blank for a few minutes until Roblox's image check clears them. Write
   down any importer warnings for Claude.
5. Right-click **ReplicatedStorage → Insert from File → `roblox_port/SpiderManData.rbxmx`**, then save.
6. Open Claude Code in the repository folder and paste `PROMPT.md`.
7. Play-test when it asks. It can measure everything except how the controls feel.
