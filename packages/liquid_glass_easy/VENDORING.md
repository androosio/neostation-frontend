# Vendoring notes — liquid_glass_easy

Upstream: https://github.com/AhmeedGamil/liquid_glass_easy — **3.5.0** from pub.dev.

Vendored because the lens needs a change the published API cannot express. Grep the
sources for `NEOSTATION VENDOR PATCH` to find every local delta.

## What was copied

`lib/` plus `pubspec.yaml`, `LICENSE`, `CHANGELOG.md`, `README.md` and
`analysis_options.yaml`. The upstream `showcases/` (24 MB of demo media) and
`example/` are not carried over.

## Local deltas

**1. Import-time mechanics** (commit "chore(deps): vendor liquid_glass_easy 3.5.0")

- `resolution: workspace` and `publish_to: none` in `pubspec.yaml`, matching the
  other members of this repo's pub workspace.
- `flutter_lints` `^5.0.0` → `^6.0.0`: a pub workspace resolves a single version
  across every member and the app root is on 6.
- `dart format` over the package, because CI formats the whole repo
  (`dart format --set-exit-if-changed .`). 26 of 70 files changed.
- The `screenshots:` entry was dropped, since `showcases/` is not vendored.

**2. Shared backdrop key** (`lens/liquid_glass_lens.dart`,
`lens/render_liquid_glass_lens.dart`)

Upstream renders each Impeller lens as **two** stacked `BackdropFilterLayer`s — a
blur below and an `ImageFilter.shader` on top, so the shader refracts an
already-blurred backdrop. Neither carries a `BackdropKey`, so every blur pass
snapshots the whole scene independently: N lenses on a screen cost N full-screen
backdrop reads per frame, and the cost tracks the *number* of glass surfaces
rather than their area.

The patch reads `BackdropGroup.of(context)?.backdropKey` in the lens widget and
threads it to `BackdropFilterLayer.backdropKey` on the **blur** pass only. Lenses
sharing a group then share one snapshot.

The shader pass deliberately keeps no key: it overlaps its own lens's blur output,
and Flutter's contract is that overlapping backdrop filters must not share a key
(the overlap would render as though only one filter applied). Lenses in the same
group must likewise not overlap each other — NeoStation's chrome surfaces are
disjoint.

With no ancestor `BackdropGroup` the key is null and behaviour is exactly upstream,
so the patch is inert everywhere the app has not opted in.

## Re-vendoring a newer upstream

1. `cp -r ~/.pub-cache/hosted/pub.dev/liquid_glass_easy-<v>/{lib,pubspec.yaml,LICENSE,CHANGELOG.md,README.md,analysis_options.yaml} packages/liquid_glass_easy/`
2. Re-apply section 1 (pubspec mechanics + `dart format packages/liquid_glass_easy`).
3. Re-apply section 2, or drop it if upstream has adopted `BackdropKey` itself.
