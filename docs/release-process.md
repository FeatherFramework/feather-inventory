# Inventory checks and releases

## Code changes

1. Update main and create a feature branch. Make the code, documentation and test
   changes. For a resource change intended to ship, update both fxmanifest.lua
   and web/package.json to the same semantic version (patch for fixes, minor for
   compatible features, major for breaking changes). CI-only changes need no bump.
2. Push the feature branch and open a pull request. GitHub runs all configured
   checks and builds a verified test archive without publishing a release.
3. Complete focused live acceptance when native behavior changes, obtain the
   required independent review, and merge. Main runs the checks again without
   publishing. Coordinate Inventory/Weapons deployment when their contracts change.

## Publish intentionally

After the merged main checks pass, a maintainer pushes a NEW version tag to the
FeatherFramework repository. For example, if both version files now say 0.11.1,
run these in a local terminal from the Inventory repository:

```sh
git fetch upstream
git switch main
git pull --ff-only upstream main
git tag 0.11.1
git push upstream refs/tags/0.11.1
```

Use the actual new version, not the example. Inspect local changes before switching
branches. Never move/reuse a tag or force-push it. A v prefix is also accepted, but
keep the repository's established bare-version convention. Do not manually create
the GitHub release first: the tag workflow creates it after validation.

The tag run checks matching semantic versions, main ancestry, the full regression
suite, UI build and archive integrity. Only then does it create the GitHub release
and attach feather-inventory.zip and its SHA-256 checksum. Hyphenated prerelease
versions are marked prerelease. A failed run does not automatically retry or
overwrite an existing release; inspect the error before taking further action.
This changes Inventory's publication process only; other resources retain their
own release triggers.

Version equality checks cannot decide whether a developer intended a resource
change to ship. Reviewers still verify the bump. A forgotten bump does not trigger
an automatic main release, and an already-existing tag cannot publish a new one.

Installers use the resulting release archive, not the source checkout. These CI
changes themselves require no server deployment, refresh, database work or restart.
