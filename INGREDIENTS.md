# Build ingredients

Everything this Action is built from, and how a change to it reaches a release. An
*ingredient* is an input to the product; the *own upstream* is the thing a repo exists to port.

**This repo is its own upstream.** The Action -- its `action.yml` and `scripts/` -- was written
here. The guest it boots is built by `Mavergreen/packer-plugin-macosx`, which is an ingredient.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| the Action (own upstream) | `UPSTREAM_VERSION` (`1.0`), and the commit count | **untrackable**: nothing external releases it; it is this repo | every push to main cuts `v1.0.<count>` and then moves `@v1` |
| `packer-plugin-macosx`: the plugin and its Mavericks template, which build the guest | `components/packer-plugin-macosx/version` | ✅ customManager, `github-releases` | a new cache key: the next consumer run (or the warmer) builds and pushes the new guest |
| `age`, `oras`, `zstd`, QEMU, `packer` | installed on the runner at run time | **untrackable** for QEMU and `zstd` (the runner's apt: Ubuntu chooses the version); `age`, `oras` and `packer` are pinned where Task 6/7 install them | a pinned tool's bump is a repackage; none of them changes the cached guest |
| shipyard's scripts and workflows | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a moving tag: content changes without the pin changing, so nothing auto-repackages |

Not ingredients: the workflows and the tests are this repo's own recipe.

## Declared state

- upstream: UPSTREAM_VERSION
- plugin: components/packer-plugin-macosx/version

## Release model

**release-model: auto-cut.** Every push to main cuts a release and moves `@v1`, as
`Mavergreen/shipyard` does, although this repo is its own upstream (whose family default is a
deliberate, dispatched release). The reason is shipyard's: consumers ride the moving `@v1`, so a
fix reaches every consumer only by being released, and a fix that waits for a person to
dispatch it is a fix every consumer's CI keeps failing without.

## Conformance deviations

- scheme: this repo is its own upstream and ships a GitHub Action consumed through a moving major tag, so it versions itself as semver `v1.0.<commit count>` (shipyard's shape), with no -mavericks.N axis to carry.
