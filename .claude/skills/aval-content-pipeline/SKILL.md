---
name: aval-content-pipeline
description: Production pipeline for authoring AVAL interactive video assets from AI-generated video (Grok Imagine or similar). Use when creating/planning .avl content, writing motion.json state graphs, crafting video-generation prompts, fixing loop seams or transition pops, or setting up the generate→normalize→compile→preview loop.
---

# AVAL Content Production Pipeline

Guidance for producing `.avl` interactive video assets from AI-generated
clips. The format's core constraint drives everything: units are frame
ranges of source video, transitions commit at portal frames with
`exact-authored` continuity — **the player cuts, it never blends**. All
production work reduces to making boundary frames pixel-matched.

## Format budgets (hard caps per asset, lower-only overrides)

32 states · 64 edges · 96 units · 16 ports/body · 32 input bindings ·
4 renditions · one fixed frame rate per asset (grass-rabbit: 24fps).
Source: `packages/format/src/constants.ts` (`FORMAT_DEFAULT_BUDGETS`),
`packages/graph/src/limits.ts` (`GRAPH_LIMITS`).

## Workflow order

1. **Graph first.** Write `motion.json` before generating any video.
   For each interactive behavior author the triple `X-in` (finite),
   `X-loop` (loop), `X-out` (finite), plus one shared `idle-loop` and an
   optional `intro` one-shot. Template: `examples/grass-rabbit/motion.json`
   (5 units, 4 states, 5 edges — copy the folder, swap ranges/source).

2. **Hub-pose pattern** (the key scaling trick). Every clip starts AND
   ends at one neutral "hub" pose. Idle = hub→subtle motion→hub; each
   gesture = hub→action→hub. All boundaries then match by construction,
   portal frames are trivial, and each new gesture costs one generation +
   one `units[]` entry. This is what makes 100s-of-gestures characters
   (talking heads etc.) feasible within the portal model.

3. **Generation (Grok Imagine or similar):**
   - Generate the hub still FIRST (image mode). It is the conditioning
     anchor for every clip — never regenerate it mid-project.
   - Always image→video conditioned on the hub still, never text→video
     (text-only never reproduces a matching first frame).
   - When a unit must end somewhere new (e.g. `hover-in` ending at the
     hover pose), chain: last frame of clip A becomes the image
     conditioning for clip B.

4. **Prompt template** — every prompt needs all four ingredients:
   - Camera lock: "static locked-off camera, tripod shot, no camera
     movement, no zoom, no pan"
   - Single action: "single continuous shot, no cuts" + exactly one
     described motion
   - Explicit start AND end pose: "begins motionless in the exact
     starting pose … returns to the exact same resting pose and holds
     still"
   - Stability: "consistent lighting, background unchanged"
   For loops add: "subtle idle motion, seamless loop, minimal movement,
   character stays in place".

5. **Post-processing:**
   - Normalize: `ffmpeg -i clip.mp4 -r 24 -vf scale=1280:720 …` (one
     fps/resolution across all clips before compiling).
   - Cut at true pose matches, not clip ends: find each clip's
     best-matching frame against the hub still (per-frame diff) and trim
     there — AI clips rarely end exactly where prompted.
   - Loop seams: ping-pong (forward+reversed) for subtle non-directional
     idle motion, or optical-flow blend the seam
     (`ffmpeg -vf minterpolate`) over the last/first few frames.
   - Color-match every clip against the hub still (shared LUT) —
     inter-clip color drift is the most common visible transition artifact.
   - Concatenate to ONE master mp4 in unit order; the frame ranges become
     `units[].range` (grass-rabbit's `sources[0]` is one continuous mp4).

6. **Compile & preview loop:**
   - `avl compile motion.json --out public/<name>.avl --force`
     (see `examples/grass-rabbit/package.json` scripts).
   - Preview in the web playground/example first (instant); check the
     Flutter example (`flutter/scripts/run.sh`) after.
   - The compiler enforces budgets and continuity — treat its errors as
     the authority on legal boundaries.

## Debugging transition pops

- Pop at portal: boundary frames don't match — re-trim both clips to the
  hub frame, or re-chain clip B from clip A's actual last frame.
- Pop only in color/brightness: color drift — LUT-match the clips.
- Loop "breathes" or jumps: loop seam — ping-pong or minterpolate, or
  regenerate with a stronger "minimal movement" prompt.
- Compiler rejects a range: frame math off by one — ranges are
  [start, end) frame indices into the master source at the asset fps.

## First-project checklist

Copy `examples/grass-rabbit/` → make hub still → generate idle-loop +
one gesture clip → normalize/trim/concat → edit ranges in motion.json →
compile → playground → iterate. Scale out gestures only after the
3-state graph plays cleanly.
