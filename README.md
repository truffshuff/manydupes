# Duplicate Adjudicator

Duplicate Adjudicator is a standalone plugin for Manyfold administrators. It compares files that share an indexed SHA-512 checksum, including files with different names or extensions. It targets Manyfold 0.154.4 and subsequent 0.154.x patches. It uses your existing administrator session and needs no additional gems, services, or database migrations.

## Install or upgrade

1. From the GitHub release, download the asset named `duplicate_adjudicator.zip`. [GitHub releases](https://github.com/truffshuff/manyfold-duplicate-adjudicator/releases)
2. Sign in as a Manyfold administrator, upload the ZIP in **Settings → Plugins**, and restart Manyfold. Keep the asset filename when upgrading so it replaces the existing plugin.
3. Open **Duplicates** in the navigation bar or visit `/duplicate_adjudicator/` relative to your Manyfold root.

For a manual install, extract the ZIP into your configured plugin directory. The resulting layout is `<plugins>/duplicate_adjudicator/duplicate_adjudicator.gemspec`. Use a persistent, writable plugin directory. The defaults are `/usr/src/app/plugins` for standard Docker images and `/config/plugins` for Solo. Use your configured `PLUGINS_PATH` if you set one. [Manyfold plugin installation guide](https://manyfold.app/sysadmin/plugins)

## Review a group

- Filter by library, filename, folder, or model name. A matching copy brings the whole checksum group into view, including copies in other libraries.
- Click **Open for review** to expand the group. Every copy on the current page has a card with its preview, path, size, roles, and visible collection memberships. Use **Use on left** or **Use on right** to choose the pair for checksum verification and storage actions. Larger groups are paginated and keep the selected pair visible. A shared-path badge identifies duplicate records that reference the same indexed path within one library.
- Use **Verify checksum** to hash the stored attachment, up to 64 MiB per copy. Use the file and model links to inspect each copy in Manyfold.
- **Needs review** hides groups you finish and brings later groups forward to fill the page. Linking part of a group leaves its remaining independent copies eligible for review. Use **All groups** to revisit completed groups.
- Choose **Mark reviewed** or **Keep all copies** to hide a group when you collapse it. **Review later** keeps it in the queue. A change to the indexed group resets saved decisions and acknowledgments for copies without a native warning.
- Use **Acknowledge copy** on a card or **Acknowledge all copies** below the cards. The progress count at the top covers every indexed copy, regardless of extension. Acknowledging an existing warning updates Manyfold’s **Problems** screen. Copies without a native warning are acknowledged in your plugin review history. Warnings in progress stay open. Use **Reopen copy** or **Reopen group** to reverse the acknowledgment.

**Largest estimated savings** sorts by the total indexed size of each group after subtracting its largest copy. This estimate uses indexed sizes and can include copies that already share storage. Use **Review hard-link plan** for filesystem eligibility and an estimate for the selected targets.

### Save reviews across browsers

Review decisions and acknowledgments for copies without a native warning follow your Manyfold account. By default, the plugin stores them in `.duplicate-adjudicator-reviews` inside the plugin directory, alongside the `duplicate_adjudicator` folder. Set `DUPLICATE_ADJUDICATOR_REVIEW_ROOT` to persist them elsewhere. The chosen directory’s parent must already exist and be writable by Manyfold.

When you first open the upgraded plugin in a browser that has older reviews, it imports decisions for matching indexed groups that have no saved server decision.

## Link copies and retain an original

A hard link keeps both Manyfold paths, filenames, and collection entries while sharing the stored bytes. Edits made in place affect all linked copies. The files and the restore folder must be on the same writable filesystem mount. [Linux hard-link documentation](https://man7.org/linux/man-pages/man2/link.2.html)

The default restore folder is `/mnt/3DPrints/duplicates`, as seen by the running Manyfold service, including inside its container or LXC. The plugin creates it on the first confirmed link. To use another location, set `DUPLICATE_ADJUDICATOR_BACKUP_ROOT` to its absolute path and restart Manyfold. Keep the folder outside every configured library, with an existing parent on the same mount as the files.

1. Select the keeper on the left and the duplicate on the right, then choose **Review hard-link plan**.
2. Review the paths and backup location, select the confirmation checkbox, and choose **Link copies and keep backup**. The plugin checks both stored SHA-512 sums, retains the original under `<restore folder>/<batch>/files/<path relative to mount>`, and atomically replaces the right path with a hard link.
3. Open **Restore backups** to restore the original or explicitly purge it. The plugin verifies the current path and contents before acting. If the file has moved or changed, it retains the saved original for manual recovery.

For a larger group, open **Choose multiple copies to link**, choose the targets shown in that comparison, and select **Review batch hard-link plan**. The left copy is the keeper. The plan flags ineligible targets and the results link to each retained original. If an individual target fails verification, the plugin continues checking the other confirmed targets.

The warning checkbox on a link plan applies after verification. A single link can acknowledge both warnings in a two-copy group. In a larger group a single link acknowledges the right copy, and a batch acknowledges each successfully linked target. Restoring an original reopens warnings acknowledged by that link.

Retained originals still occupy disk space. **Restore backups** estimates the space that purging can reclaim using the allocated blocks of originals that are only linked from the backup directory. Treat that total as an upper bound. Snapshots and shared blocks can reduce actual savings.

### Make a linked copy independent

Select two linked copies at distinct paths and choose **Review independent copy**. If that action has yet to appear, open **Review hard-link plan** to check that the paths share storage. On confirmation, the plugin uses the current right-hand bytes to create an independent file at the same path and preserves its ownership, mode, and modification time. This requires enough free space for a separate file and works after the original backup has been purged.

## Verify or remove the plugin

On a test group, confirm the counts and paths, open the available previews, and verify a known matching attachment. Check that a review decision appears in a second browser signed in with the same account. Link and restore a test pair, check both Manyfold URLs and the backup contents, and confirm the warnings on Manyfold’s **Problems** screen before and after restoring.

To remove the plugin, delete its installed folder and restart Manyfold. Restore any files and reopen any warnings you want to revert before removing the plugin. Review data and retained originals are stored separately from the installed plugin folder.

[Release history](CHANGELOG.md)
