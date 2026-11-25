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

## Link copies and retain an original

A hard link keeps both Manyfold paths and collection entries while sharing the stored bytes. Edits in place affect all linked copies. The files and the restore folder must be on the same writable mount. [Linux hard-link documentation](https://man7.org/linux/man-pages/man2/link.2.html)

The default restore folder is `/mnt/3DPrints/duplicates` **inside the Manyfold container**. The plugin creates it on the first confirmed link. If the mount has a different container path, set `DUPLICATE_ADJUDICATOR_BACKUP_ROOT` to its equivalent absolute path and restart Manyfold. Keep the restore folder alongside your library folders, outside all configured libraries. The plugin refuses overlapping paths.

1. Select the keeper on the left and the duplicate on the right, then choose **Check disk savings for right copy**.
2. Review both paths and the backup location. Select the confirmation checkbox and choose **Link copies and keep backup**. The plugin checks both stored SHA-512 sums, saves the original under `duplicates/<batch>/files/<path relative to mount>`, then replaces the right path atomically. The Manyfold records stay at their original paths.
3. Open **Restore backups** to restore the original or explicitly purge it. The plugin verifies the current path and file contents before acting. If the file was edited or moved, the saved original remains available for manual recovery.

The original uses disk space until purged. The backup list shows the right copy’s estimated allocation, which is an upper bound on the space a purge can release. Filesystem snapshots and shared blocks can reduce actual savings.

The optional warning action runs after the link is verified. For a pair with two indexed records it can acknowledge both warnings. For a larger group it acknowledges only the selected right copy. Restoring reopens the affected warnings.

This release works from indexed file checksums. Supported and unsupported variants, re-exported meshes, and whole-model folders are outside the match unless their indexed files share a checksum.

## Verify the installation

Open a known group and compare the counts and paths with the linked file pages. Confirm cached and embedded previews, verify a known matching attachment, and check that a browser decision survives a reload. Use a test pair to link and restore and check both original Manyfold URLs. Confirm its stored paths and backup contents, as well as the Problems list before and after restoring.

To remove the plugin, remove its installed folder and restart Manyfold. Reopen any native warnings you want to restore before uninstalling.
