# wp-media-clean.sh — design

Date: 2026-09-08
Status: approved, ready for implementation planning

## Purpose

Reclaim disk space on the VPS by removing image files that no WordPress site
uses any more, without ever destroying a file that is still referenced.

The tool is a new command in the `prawner` family, following the same
conventions as `wp-site.sh` and `wp-update.sh`: a single self-contained bash
script in `bin/`, run as root, discovering sites by looking for `wp-config.php`
under `/var/www`, driving each site through `wp-cli` as the user that owns the
installation.

## Scope

Three distinct classes of waste, all handled by the same command:

1. **Orphan attachments** — rows in `wp_posts` with `post_type='attachment'`
   that nothing references.
2. **Orphan files** — files under `wp-content/uploads/` that correspond to no
   attachment row (leftovers from failed imports, removed plugins, migrations).
3. **Stale thumbnails** — generated size variants (`name-800x600.jpg`) for
   image sizes that the current theme and plugins no longer register.

Out of scope: non-image uploads are treated exactly like images (the logic is
filename-based and does not care about MIME type); the tool does not
regenerate thumbnails, does not optimise images, and installs nothing on the
sites it operates on.

## Non-negotiable safety properties

These drive every decision below.

- **Dry-run is the default.** The command with no arguments only reports.
  Moving anything requires an explicit `--apply`.
- **Removal is a move, not a delete.** Files go to a quarantine directory and
  the affected database rows are dumped alongside them. Actual deletion
  happens only when a quarantine set falls out of the retention window.
- **Every heuristic errs towards keeping the file.** Where a rule is
  imprecise, it is imprecise in the direction of a false "in use", never a
  false "orphan".

## Detection

For each site the script builds three sets once, then intersects them.

### The haystack

A single `wp db query` with `UNION ALL` over every column that can carry a
reference:

- `posts.post_content` and `posts.post_excerpt`, for `post_type <> 'attachment'`
- `postmeta.meta_value`, excluding the meta keys `_wp_attached_file`,
  `_wp_attachment_metadata` and `_wp_attachment_backup_sizes`
- `options.option_value`
- `termmeta.meta_value`
- `usermeta.meta_value`

The table prefix comes from `wp config get table_prefix`.

Two details matter:

- **No `post_status` filter.** Drafts, revisions, scheduled posts and trashed
  content all contribute to the haystack. An image used only by an unpublished
  draft counts as used.
- **The excluded meta keys are mandatory.** `_wp_attached_file` holds the
  attachment's own path and `_wp_attachment_metadata` holds its own thumbnail
  names. Without the exclusion every attachment matches itself and nothing is
  ever reported.

Unless `--no-scan-files` is given, the haystack is extended with a
`grep -rIoF -f <names>` over `wp-content/themes`, `wp-content/plugins` and
`wp-content/mu-plugins`, catching images referenced from CSS, PHP, JS or JSON
that the database knows nothing about.

Matching is a single `grep -oF -f <names> <haystack>` invocation: GNU grep
compiles a fixed-string pattern file into an Aho-Corasick automaton, so
thousands of filenames are matched against the whole haystack in one pass
rather than one scan per filename.

### The ID set

Filename matching alone is not sufficient. The featured image lives in
`_thumbnail_id` as a bare number, ACF image fields store the attachment ID,
and the WooCommerce product gallery stores `12,45,78`. An attachment is
therefore also considered used when its ID appears as a reference.

The ID set is built from targeted queries, *not* by extracting every integer
from the haystack — a low ID such as `12` occurs everywhere in serialized data
and would make the tool report nothing at all. The sources are:

- `postmeta.meta_value` matching `^[0-9]+$` (ACF single image, `_thumbnail_id`)
- `postmeta.meta_value` matching `^[0-9]+(,[0-9]+)+$` (galleries)
- `i:N;` and `s:len:"N"` tokens inside serialized `postmeta` and `options`
  values (theme mods, page builder settings)
- the `custom_logo` and `site_icon` options
- `wp-image-N` classes and `"id":N` block attributes inside `post_content`

A bare integer meta value that happens to equal an attachment ID for an
unrelated reason (for example `_menu_item_object_id`) produces a false "in
use". That is the acceptable direction of error.

### The inventory

A join of `posts` and `postmeta._wp_attached_file` over
`post_type='attachment'`, yielding ID, upload date and path relative to the
uploads base directory.

### Classification

| Class | Removable when |
|---|---|
| Orphan attachment | its basename is absent from the haystack **and** its ID is absent from the ID set **and** it is older than `--min-age` (default 30 days) **and**, if `--keep-attached` was given, `post_parent = 0` |
| Orphan file | it lives under `uploads/`, is not the `_wp_attached_file` of any attachment, is not a thumbnail derived from one, and its name is absent from the haystack |
| Stale thumbnail | it is `<base>-<W>x<H>.<ext>` of a live attachment, `WxH` is not among the sizes reported by `wp media image-size`, **and** its filename is absent from the haystack |

`post_parent` is deliberately not a criterion by default. An image uploaded
through a post's editor and later removed from the content keeps its
`post_parent`, and that is precisely the most common orphan. `--keep-attached`
is available for operators who consider the association enough to protect the
file.

The haystack check on stale thumbnails is not optional. `srcset` attributes
written into `post_content` name the thumbnail files directly, so a size that
is no longer registered may still be referenced by existing content.

### Known limitations

- References that URL-encode the filename (`%20` for spaces) are not matched by
  a plain basename search. Mitigation: when a basename contains characters that
  URL encoding alters, its encoded variant is added to the pattern file as
  well. Filenames mangled in other ways (HTML entities, CDN rewriting) remain
  undetected, and would be reported as orphans.
- Images referenced only by an external system (a CDN manifest, another site
  hotlinking) are invisible to the tool.

Both are why quarantine, and not deletion, is the removal mechanism.

## Removal

### Order of operations

For orphan attachments the order is what protects the data:

1. Export the database rows, preserving the original IDs:
   `wp db export - --tables=<prefix>posts --where="ID IN (...)"` and the same
   on `postmeta` with `--where="post_id IN (...)"`, both with
   `--no-create-info`. A manifest rebuilt with `wp post create` would assign
   new IDs and be useless in exactly the case where a restore is needed.
2. Move — not copy — the original file and every one of its thumbnails into
   the quarantine, preserving paths relative to the docroot.
3. `wp post delete <ID> --force`. The files are already gone, so WordPress
   simply cleans up the rows, the postmeta and the term relationships
   correctly.

Orphan files and stale thumbnails are moves only, with no database change,
with one exception below.

### Thumbnail metadata

Removing a thumbnail file while leaving its entry in
`_wp_attachment_metadata` makes WordPress keep emitting the URL in `srcset`,
producing 404s. That value is serialized PHP, which bash handles badly, so the
script uses a short inline `wp eval` (no additional file to install) to unset
the removed sizes from the array.

On restore the metadata is rebuilt with `wp media regenerate --only-missing`
for the affected attachments.

### Quarantine layout

```
/var/backups/wp-media/<site_slug>/<stamp>/
  files/wp-content/uploads/2023/04/photo.jpg   # paths relative to the docroot
  rows/posts.sql
  rows/postmeta.sql
  manifest.tsv                                  # class, path, attachment ID
  report.txt
```

`<site_slug>` is derived the same way `wp-update.sh` derives it (the path
under `/var/www` with `/` replaced by `_`), so a domain hosting several
installations keeps them separate.

`KEEP_QUARANTINE` (default 3) sets how many sets per site are retained,
mirroring `KEEP_BACKUPS` in `wp-update.sh`. Pruning older sets is the only
operation that deletes a file for real. It runs at the end of a successful
`--apply` pass over a site, never during a dry run and never for a site the
current invocation did not touch.

`--apply` does not ask for confirmation. The typed-domain prompt that
`wp-site.sh remove` uses is there because that operation is irreversible;
this one is not.

### Restore

`--restore <stamp> --site <domain>` moves the files back to their original
locations, applies `chown` to the site's owner and group, imports
`rows/*.sql`, and regenerates the metadata of the affected attachments. It
refuses to run if a destination file already exists, reporting the conflict
rather than overwriting.

## Command line

```
wp-media-clean.sh                                  # report only, touches nothing
wp-media-clean.sh --site example.com --apply
wp-media-clean.sh --only thumbs --apply            # attachments|orphans|thumbs
wp-media-clean.sh --list-quarantine --site example.com
wp-media-clean.sh --restore <stamp> --site example.com

  --site <domain>      restrict to sites whose path contains <domain>
  --apply              move to quarantine (without it, report only)
  --only <class>       one of attachments, orphans, thumbs (default: all)
  --min-age <days>     ignore attachments newer than this (default 30)
  --keep-attached      treat post_parent <> 0 as in use
  --no-scan-files      skip the grep over themes and plugins
  --list-quarantine    list the available quarantine sets
  --restore <stamp>    restore a quarantine set
  -h, --help
```

Environment overrides, consistent with the rest of the repository:
`WWW_ROOT`, `QUARANTINE_ROOT` (default `/var/backups/wp-media`), `LOG_DIR`
(default `/var/log/wp-media-clean`), `KEEP_QUARANTINE`, `MIN_AGE_DAYS`,
`WP_CLI_CACHE_ROOT`.

The report prints, per site and per class, the number of items and the
reclaimable bytes, plus the largest entries; the complete list goes to the log
file. Exit status is non-zero if any site failed.

## Repository changes

- `bin/wp-media-clean.sh` — the new command.
- `install.sh` / `uninstall.sh` — add the name to the loop that installs and
  removes the commands, and mention it in the usage summary. No cron job.
- `tests/run.sh` — a dependency-free bash runner covering the pure functions:
  basename extraction, the `-WxH.` thumbnail pattern, ID token extraction and
  the set difference. The script is written so those functions can be sourced
  in isolation, with no WordPress and no database. End-to-end verification is
  a `--dry-run` against a real site.
- `README.md` and `CHANGELOG.md` — document the new command.

## Assumptions to verify during implementation

- `wp db export` accepts `--tables` and passes `--where` and
  `--no-create-info` through to `mysqldump`.
- `wp db query` accepts `--skip-column-names` and passes it to the `mysql`
  client.
- `wp media image-size --format=csv` lists the registered sizes.

If any of these is wrong, the fallback is calling `mysqldump` and `mysql`
directly with the credentials read from `wp-config.php`, which the script can
already parse.
