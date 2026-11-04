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

## Publish through GitHub

After the merged main checks pass:

1. Open FeatherFramework/feather-inventory, then Releases > Draft a new release.
2. Select/create the new version tag (for example 0.12.1) and target main. The
   tag must match both version files. Do not reuse established release tags.
3. Enter the title and release notes; Generate release notes is optional.
   Mark prerelease versions as prereleases when appropriate.
4. Click Publish release. Do not manually upload build files.
5. Wait for Inventory checks and release in Actions to finish. Confirm the release
   contains feather-inventory.zip and feather-inventory.zip.sha256 before
   announcing it as ready for installation.

The published-release event runs matching-version and main-ancestry guards,
all tests, the UI build and archive verification against the tagged commit.
Only a successful package job allows upload to the existing release. It does
not create another release or overwrite existing assets. PR/main checks remain
unchanged; pushing a tag alone no longer publishes or builds a release.

A published release is visible while checks/build run. If they fail, it has not
produced an accepted installer; inspect the failed step. Do not delete or move
established tags to bypass failures. Editing a release alone does not rerun the
workflow. This process expects releases that allow assets to be attached after
publication; immutable releases are not supported.

These workflow changes need no resource version bump, server copy, refresh,
database work or restart. Other resources retain their own release workflows.

## One-time recovery of the empty 0.12.0 release

The original 0.12.0 was published before the tag-triggered workflow tried to
create it. Package verification passed but release creation failed; no installer
assets were attached. Its code is already merged/live tested. Do not revert code
or change its version to repair publication.

After this workflow fix is merged and main checks pass, remove only the empty
0.12.0 GitHub release and its tag. Recreate 0.12.0 through the release page with
target main. This one-time correction ensures the tagged source contains the
published-release workflow. Preserve the failed run as evidence. Confirm there
are still no assets before removing it; stop and reassess if contents changed.
Do not use this tag-recreation procedure for established releases in consumer use.

Reviewers still check whether resource changes deserve a version bump. Installers
use the generated archive, not a source snapshot or development test bundle.
