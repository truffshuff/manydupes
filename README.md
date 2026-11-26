# Duplicate Adjudicator

Duplicate Adjudicator is a standalone Manyfold plugin for comparing copies that share an indexed SHA-512 checksum. It targets Manyfold 0.154.4 and subsequent 0.154.x patches. It uses your existing administrator session and needs no additional gems, services, or database migrations.

## Install

1. Sign in as an administrator and open **Settings → Plugins**.
2. Upload `duplicate_adjudicator.zip` and restart Manyfold. Keep the filename when upgrading an existing installation. For a manual install, extract the ZIP into your configured plugin directory. The resulting layout is `<plugins>/duplicate_adjudicator/duplicate_adjudicator.gemspec`.
3. Open **Duplicates** in the navigation bar, or visit `/duplicate_adjudicator/` relative to your Manyfold root.

The default plugin paths are `/usr/src/app/plugins` for standard Docker images and `/config/plugins` for Solo. Use your configured `PLUGINS_PATH` for a manual install. [Manyfold plugin installation guide](https://manyfold.app/sysadmin/plugins)

## Review a group

- Filter by library, filename, folder, or model name. A matching copy brings the whole checksum group into view, including copies in other libraries.
- Click **Open for review** to expand the group in the queue. Every copy on the current page has a card with its preview, path, size, roles, and visible collection memberships. Use **Use on left** or **Use on right** to choose the pair for checksum verification and storage actions. Larger groups are paginated and keep the selected pair visible. The shared-path badge identifies duplicate records that reference the same indexed path within one library.
- Use **Verify checksum** to hash the currently stored attachment, up to 64 MiB per copy. Use the file and model links to inspect each copy in Manyfold.
- **Needs review** hides groups after all their copies are linked or every indexed copy is acknowledged. The queue brings later groups forward as you finish the visible ones. **All groups** shows the full list. A group with another independent copy stays available for review.
- Choose **Mark reviewed** or **Keep all copies** to hide a group when you collapse it. Saving a preference leaves room to decide what to do next, and **Review later** keeps the group in the queue. Decisions sync across browsers signed in to the same Manyfold account. A changed set of indexed copies prompts a fresh review.
- Use **Acknowledge copy** on any card or **Acknowledge all copies** below the comparison cards to review a whole group. The acknowledgment count is at the top of the comparison. Native duplicate warnings are acknowledged on Manyfold’s Problems screen. Acknowledgments for copies without a warning are saved with your Manyfold account. Warnings in progress remain open for review. Use **Reopen copy** or **Reopen group** to reverse those choices.

**Largest estimated savings** sorts by the sum of indexed duplicate sizes after keeping one copy. It ranks candidates before checking actual allocation, shared paths, already linked files, or filesystem eligibility. **Restore backups** gives a separate total for the estimated space held by saved originals.

Review decisions are stored beside the installed plugins in the persistent `.duplicate-adjudicator-reviews` directory. Set `DUPLICATE_ADJUDICATOR_REVIEW_ROOT` to override this location. Its parent must exist and be writable by Manyfold. When you open the upgraded plugin in a browser with older saved reviews, it imports choices that still match the indexed group and preserves existing server decisions.


## Link copies and retain an original

A hard link keeps both Manyfold paths and collection entries while sharing the stored bytes. Edits in place affect all linked copies. The files and the restore folder must be on the same writable mount. [Linux hard-link documentation](https://man7.org/linux/man-pages/man2/link.2.html)

The default restore folder is `/mnt/3DPrints/duplicates` **inside the Manyfold container**. The plugin creates it on the first confirmed link. If the mount has a different container path, set `DUPLICATE_ADJUDICATOR_BACKUP_ROOT` to its equivalent absolute path and restart Manyfold. Keep the restore folder alongside your library folders, outside all configured libraries. The plugin refuses overlapping paths.

1. Select the keeper on the left and the duplicate on the right, then choose **Review hard-link plan**.
2. Review both paths and the backup location. Select the confirmation checkbox and choose **Link copies and keep backup**. The plugin checks both stored SHA-512 sums, saves the original under `duplicates/<batch>/files/<path relative to mount>`, then replaces the right path atomically. The Manyfold records stay at their original paths.
3. Open **Restore backups** to restore the original or explicitly purge it. The plugin verifies the current path and file contents before acting. If the file was edited or moved, the saved original remains available for manual recovery.

For a larger group, expand **Choose multiple copies to link** and select copies from the current comparison page. The batch preview flags ineligible files and the results link to each saved original. A stale or inaccessible target does not stop the other confirmed targets from being processed.

To edit a linked file separately, select linked copies at two distinct paths and choose **Review independent copy**. On confirmation the plugin writes the current right-hand bytes to a new independent file at the same path. This works after purging the old original and requires space for another copy. The operation preserves the file’s ownership, mode, and modification time.


The original uses disk space until purged. The backup list shows the right copy’s estimated allocation, which is an upper bound on the space a purge can release. Filesystem snapshots and shared blocks can reduce actual savings.

The optional warning action runs after the link is verified. For a pair with two indexed records it can acknowledge both warnings. For a larger group it acknowledges only the selected right copy. Restoring reopens the affected warnings.

This release works from indexed file checksums. Supported and unsupported variants, re-exported meshes, and whole-model folders are outside the match unless their indexed files share a checksum.

## Verify the installation

Open a known group and compare the counts and paths with the linked file pages. Confirm cached and embedded previews, verify a known matching attachment, and check that a browser decision survives a reload. Use a test pair to link and restore and check both original Manyfold URLs. Confirm its stored paths and backup contents, as well as the Problems list before and after restoring.

To remove the plugin, remove its installed folder and restart Manyfold. Reopen any native warnings you want to restore before uninstalling.
