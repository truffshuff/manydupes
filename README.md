# Duplicate Adjudicator

Duplicate Adjudicator is a standalone Manyfold plugin for comparing copies that share an indexed SHA-512 checksum. It targets Manyfold 0.154.4 and subsequent 0.154.x patches. It uses your existing administrator session and needs no additional gems, services, or database migrations.

## Install

1. Sign in as an administrator and open **Settings → Plugins**.
2. Upload `duplicate_adjudicator.zip` and restart Manyfold. Keep the filename when upgrading an existing installation. For a manual install, extract the ZIP into your configured plugin directory. The resulting layout is `<plugins>/duplicate_adjudicator/duplicate_adjudicator.gemspec`.
3. Open **Duplicates** in the navigation bar, or visit `/duplicate_adjudicator/` relative to your Manyfold root.

The default plugin paths are `/usr/src/app/plugins` for standard Docker images and `/config/plugins` for Solo. Use your configured `PLUGINS_PATH` for a manual install. [Manyfold plugin installation guide](https://manyfold.app/sysadmin/plugins)

## Review a group

- Filter by library, filename, folder, or model name. A matching copy brings the whole checksum group into view, including copies in other libraries.
- Click **Open for review** to expand the comparison in the queue. Select two copies to compare previews, library-relative paths, file sizes, preview and entrypoint roles, support status, and other indexed file counts. The shared-path badge identifies duplicate records that reference the same indexed path within one library.
- Use **Verify checksum** to hash the currently stored attachment, up to 64 MiB per copy. Use the file and model links to inspect each copy in Manyfold.
- Save a preferred copy, choose **Keep all copies**, or mark the group for later. Decisions are stored per account in the current browser. A change to the indexed copies or their comparison metadata prompts a new review.
- Use **Acknowledge duplicate warnings** when you want Manyfold to hide the existing duplicate warnings in that group. **Reopen ignored warnings** restores them to the active Problems list. Both actions operate on the group’s recorded duplicate warnings, except jobs in progress. The preferred-copy and review-later decisions are browser-only.

## Estimate disk savings

A hard link can retain both paths and collection entries while sharing the stored bytes. Both paths then have the same file attributes, and edits made in place through either path affect both. The paths must be on the same mount, and the filesystem must allow hard links. [Linux hard-link documentation](https://man7.org/linux/man-pages/man2/link.2.html)

Select the copy you would keep on the left and the copy whose disk usage you want to estimate on the right. **Check disk savings for right copy** examines local filesystem metadata and estimates the right copy’s allocated space. It identifies an already shared file, a different device, a change in file size, existing links, or different ownership or permissions. Snapshots and shared blocks can reduce the actual space reclaimed. The check does not change files. The workflow verifies live checksums separately and leaves storage operations manual.

This release works from indexed file checksums. Supported and unsupported variants, re-exported meshes, and whole-model folders are outside the match unless their indexed files share a checksum.

## Verify the installation

Open a known group and compare the counts and paths with the linked file pages. Confirm cached and embedded previews, verify a known matching attachment, and check that a browser decision survives a reload. Use a test group to acknowledge and reopen native warnings and check the Problems list after both actions.

To remove the plugin, remove its installed folder and restart Manyfold. Reopen any native warnings you want to restore before uninstalling.
