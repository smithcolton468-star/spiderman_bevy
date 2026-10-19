# Prompt for the local Claude Code (with the Roblox Studio MCP)

Paste everything below the line into Claude Code, opened in this repository's folder.

---

I want this repository's Spider-Man swing sandbox (Rust / Bevy 0.19.1) rebuilt in the Roblox Studio place I have open,
as close to 1:1 as Roblox allows. It's an experiment in how faithfully a Rust game can be carried into Luau, so the
Rust code is the specification. The question is never "what feels like web swinging" but "what does the Rust do, and
how do I make Luau do exactly that". It will only ever run in Studio on my machine: no publishing, no server
authority, no monetisation, no mobile or low-end tuning. Everything can run on the client.

You have the Roblox Studio MCP and this repo on disk. You do the engineering and choose the architecture, module split
and order of work. I've only fixed the things below because they decide whether the result is 1:1 or not.

## What's already in the place

A cloud session prepared `roblox_port/` (read `roblox_port/README.md`, `FORMAT.md` and `manifest.json` first), and I
have already:

- imported `roblox_port/import/SpiderMan.glb` (Rig Type Custom, Keep Zero Influence Bones on, Scale Unit Studs) with
  the 3D Importer. I'm **not** importing the city (`CityTowers.glb`, `CityProps.glb`); I'll build my own maps from
  parts and models (see Collision below);
- inserted `roblox_port/SpiderManData.rbxmx` into ReplicatedStorage. It holds every animation clip bit for bit, the
  skeleton, the collision triangles, layout.json, all of assets/tuning, the 11 original-game runs and reference poses.
  Its `Decoder` module reads them all (`luau/Decoder.luau`, already tested in the Luau CLI).

Find the imported models in the place yourself (names may differ from what you expect), and tell me if something is
missing or the importer warned about anything.

## Rules

- **Port; don't reinvent.** Every behaviour, constant, threshold and timer comes from the Rust source or the pack's
  data. If the Rust does something odd, keep it. If you can't find where the Rust does something, look harder or ask
  me; don't fill the gap with something plausible.
- **Roblox engine systems don't stand in for the game's.** No Humanoid, no default character, controls or camera, no
  Roblox physics for the hero and no Animator for the clips. The hero is the Rust `Hero` state stepped by your port,
  collision is the Rust `World` built from the pack's triangles and boxes, and the bones are set from the clips the way
  Bevy evaluates them. Roblox draws, plays sound and reads input.
- **When something really can't be done in Roblox, stop and tell me** what it is, why, and the closest option, instead
  of quietly approximating it. Bone scale (below) and the renderer's look are already known.
- **Prove it with numbers.** The pack has checks for the hard parts; use them, and add your own comparisons wherever
  you can produce numbers from both sides.
- Don't change the Rust game. If Rust is installed (`cargo test --workspace` passes), you may write throwaway Rust
  (a test or example that prints numbers) to get reference values for anything the pack doesn't cover.

## Facts that are easy to get wrong

**Units and frames.** The simulation runs in metres, like the Rust. Anything drawn is multiplied by
`studs_per_metre` (1/0.28, in `PackInfo` and `manifest.json`); the import files are already in studs. glTF, Bevy and
Roblox are all right-handed and +Y up, and `Quat::from_rotation_y(a)` is `CFrame.Angles(0, a, 0)`. The suit faces +Z
in its own space (see `update_visual` in `src/main.rs`); the visual root sits at `hero.pos - Y * FOOT` (FOOT = 0.95).
Check the import's orientation and scale against `manifest.json` (`rest_joint_positions_studs`, `bounds_studs`) before
you build on it.

**Numbers.** The Rust computes in 32-bit floats and Luau numbers are 64-bit. A straight port drifts a few
millimetres per swing and fails 3 of the 11 oracle checks by a hair (`basic_jump`, `turn_left`, `hold_auto`). In the
`sm_traversal` port, round every arithmetic result to f32 (`vector.create(x, 0, 0).x` does it). Keep f64 only where
the Rust does: the game clock (`time`, `entry_time`) and part of `spring` in `math.rs`. With that, the Luau path
matches the Rust path to within 1 µm on every frame. (A cloud session found this while porting `sm_traversal`; if
its branch exists, start from its `roblox_port/src/` instead of porting that part again.)

**Time.** `simulate` runs on a fixed 60 Hz clock (`Time::<Fixed>::from_hz(60.)`), input is read every frame, and
rendering interpolates between the last two steps exactly as `src/presentation.rs` does. The system order in
`main()` matters (PreUpdate input, then FixedUpdate simulate, then Update build_world, animate, update_visual,
update_camera, update_hud, then PostUpdate draw_web after transforms propagate).

**Animation: Bevy 0.19.1's semantics, which the clips have to be played with.**
- Each frame `animate` (src/main.rs) gives every layer of `animation::Mixer` a clip, a seek time and a weight, with
  speed 0 and `repeat()`. Bevy still runs `ActiveAnimation::update` at speed 0, so a seek at or past the clip's
  duration wraps to `seek % duration`.
- Sampling a keyframe curve clamps to the first and last key, gives a key exactly when the time lands on one, lerps
  translation and scale, slerps rotation (glam's `Quat::slerp`: flip to the short way, lerp-and-normalise when the
  dot is above 1 − f32 epsilon), and STEP holds the earlier key.
- Blending: the active clips fold in ascending clip-name order (the graph is built from the names sorted), with
  `acc = interpolate(acc, value, weight / weight_so_far)`. One active clip is used as it is, whatever its weight, and
  a zero-weight clip is skipped.
- Every clip animates all 212 joints in translation, rotation and scale. The 19 `_mirrored` clips are already
  separate clips.

**Driving Roblox bones.** Roblox bones can't scale, so carry the scale only through joint positions:
- For each joint, compute its world position through the full TRS chain (scale included, as Bevy does) and its world
  rotation as the product of the local rotations with the scales left out. That's exactly what
  `ReferencePoses` lists.
- Deform each bone rigidly about its joint: `D = T(p·k) · R(q · q_rest⁻¹) · T(−p_rest·k)`. Then target the bone's
  world CFrame at `visualRoot · D · boneRestWorld`, where `boneRestWorld` is the bone's world CFrame at rest in the
  imported rig, relative to its root. Set `Bone.Transform` from the parent's current world CFrame and `Bone.CFrame`
  so the bone lands on that target.
- This keeps Roblox's skinning matrix equal to Bevy's apart from the scale. Remove any AnimationController or
  Animator the importer added, so nothing else writes Transform.
- The web lines start at the `LF_wrist` / `RT_wrist` joints' animated world positions.

**Collision: any map I build.** Swinging has to work on whatever parts and models I put in the place, not on a fixed
city. The Rust already supports this: anything without an authored box "collides by its own meshes and offers its
ledges" (`src/world.rs`, `environment.rs`). Swing points, zip points, perches, wall runs and the floor all come from
`World::raycast`, `sphere_cast` and friends over boxes and triangles. So build the Rust `World` from the place's
geometry, turned into triangles in metres (÷ studs_per_metre):
- Parts: the triangles of their shape at their CFrame and Size (a Block is a box, rotated parts included; wedges,
  corner wedges, cylinders and balls triangulated).
- MeshParts: their real triangles, read with `AssetService:CreateEditableMeshAsync` and scaled from MeshSize to Size.
  Unions and anything else you can't read: tell me what you did with them.
- One `world::Model` per mesh asset or shape, shared by every placement as the Rust does, with a BVH. Rebuild when
  the map changes, or say why not.
- Decide with me what counts as map (a folder, a tag, or everything anchored and collidable that isn't the hero).
- Keep the Rust's built-in street at y = 0 and its reset rules (below −20 m, or over 2,000 m from the origin), with
  the place's ground at Y = 0. Ask me if those get in the way of a bigger map.

The pack still has the sandbox city's collision (`Collision/Index`, `Collision/Models`, `Layout`). Use it as test
data, without drawing anything, to show that your Luau `World` gives the same answers as the Rust one.

**Roblox and Studio.**
- `Script.Source` and string properties stop at 200,000 characters, so keep modules under that.
- `require` caches by instance: to re-run edited code from the MCP, require a fresh clone.
- `HttpService:JSONDecode` and `EncodingService` work without HTTP access.
- Set `Players.CharacterAutoLoads = false`, use a Scriptable camera, and turn off `StarterPlayer.EnableMouseLockOption`
  (Shift is the swing).
- Esc always opens Roblox's menu. Studio may also keep some F-keys during play-testing; if F1, F3 or F12 don't reach
  the game, tell me and suggest the closest free keys.
- Roblox's `Camera.FieldOfView` is vertical, and `update_camera` already converts from horizontal; keep that conversion.
- Lighting: there are no lux or EV values in Roblox, so match `setup`'s sun direction, colours, ambient and the
  linear fog (140–600 m) as closely as Roblox allows, then show me a screenshot next to
  `screenshots/` from the Rust build so I can judge.

## Checks I want passing (report each as numbers)

1. **Import:** 212 bones with the Skeleton's names, rest joint positions and bounds as in `manifest.json`, and all 21
   suit MeshParts skinned.
2. **Pack:** `Decoder.loadClips` and `loadCollision` load in Studio: 68 clips, durations matching `Conversion`, 73
   models with the triangle counts in `Collision/Index`.
3. **The game's code:** your Luau `sm_traversal` port runs the 11 `OracleFixtures` scenarios closed loop, like
   `crates/sm_traversal/tests/oracle_paths.rs` with `replay.rs`. Every frame must stay within its tolerance, in the
   same mode, with facing within 0.5°.
4. **Animation:** your sampler, blender and forward kinematics reproduce every `ReferencePoses` entry (positions
   within 0.1 mm, rotations within 0.01°), including the three-layer blend. Then check the bones in Studio actually
   land where the targets say.
5. **World:** with the pack's sandbox city loaded as test data, the counts the Rust logs ("collision world: N boxes,
   N placed meshes (N distinct), N triangles, N perch ledges") come out the same in Luau. If you can run the Rust,
   compare a few swing-point and ledge picks directly. Then swing across a map made of plain parts and of MeshParts.
6. **Play:** the controls table in the repo README works (keyboard, mouse and a controller), with the HUD, F1 help,
   the F3 overlay and the zip diamond.

## When you finish (and at milestones along the way)

Give me a short table: feature, how it was verified, whether it's matched, approximated or not possible, and why.
Keep the Luau you write mirrored on disk under `roblox_port/src/` so it can be diffed and committed; ask me before
committing. Ask me whenever a choice changes what the game does.
