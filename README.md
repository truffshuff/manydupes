# Duplicate Adjudicator

Duplicate Adjudicator is a standalone Manyfold plugin for comparing copies that share an indexed SHA-512 checksum. It targets Manyfold 0.154.4 and subsequent 0.154.x patches. It uses your existing administrator session and needs no additional gems, services, or database migrations.

## Install

1. On a staging instance, sign in as an administrator and open **Settings → Plugins**.
2. Upload `duplicate_adjudicator.zip` and restart Manyfold. For a manual install, extract the ZIP into your configured plugin directory. The resulting layout is `<plugins>/duplicate_adjudicator/duplicate_adjudicator.gemspec`.
3. Open **Duplicates** in the navigation bar, or visit `/duplicate_adjudicator/` relative to your Manyfold root.

The default plugin paths are `/usr/src/app/plugins` for standard Docker images and `/config/plugins` for Solo. Use your configured `PLUGINS_PATH` for a manual install. [Manyfold plugin installation guide](https://manyfold.app/sysadmin/plugins)

## Review a group

- Filter by library, filename, folder, or model name. A matching copy brings the whole checksum group into view, including copies in other libraries.
- Select two copies to compare their previews, library-relative paths, file sizes, preview and entrypoint roles, support status, and the number of other indexed files in each model. The shared-path badge identifies duplicate records that reference the same indexed path within one library.
- Use **Verify checksum** to hash the currently stored attachment, up to 64 MiB per copy. The result describes the verification at the time it ran. Use the file and model links to inspect each copy in Manyfold.
- Save a preferred copy, choose **Keep all copies**, or mark the group for later. Decisions are stored per account in the current browser. Opening a group after its indexed copies or comparison metadata change prompts a new review.

This release works from indexed file checksums. Supported and unsupported variants, re-exported meshes, and whole-model folders are outside the match unless their indexed files share a checksum. Review writes go only to browser storage. Manyfold files, models, and warnings stay in place.

## Check on staging

Open a known group and compare the counts and paths with the linked Manyfold file pages. Confirm cached and embedded previews, verify a known matching attachment, and check that a decision survives a page reload. If you use S3, check verification against an S3-backed copy. Check that a regular member cannot open the plugin route.

To remove the plugin, remove its installed folder and restart Manyfold.
