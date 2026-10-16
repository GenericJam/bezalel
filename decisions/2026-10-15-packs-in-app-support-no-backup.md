# Study packs live in app support, excluded from backup
- Date: 2026-10-15
- Status: accepted

## Context
The packs (182-607 MB) were in `Mob.data_dir()/packs`, which on iOS is
Documents, backed up to iCloud. Apple rejects apps that back up data they can
download again (bezalel-lac.3). Mob had no way to set
`NSURLIsExcludedFromBackupKey`; GenericJam/mob#209 added
`Mob.Storage.exclude_from_backup/1` (Linear was full, so no MOB issue).
The alternative, `:cache` (Library/Caches), isn't backed up but iOS may
purge it when space is low, losing a 182 MB download the tools need offline.

## Decision
The packs live in `Mob.Storage.dir(:app_support)/packs`
(Library/Application Support on iOS, `filesDir` on Android, which is also
`Mob.data_dir()` there). `Bezalel.Packs.Storage.prepare/0` runs at every
start, before `Bezalel.Packs`: it creates the directory and excludes it from
backup first, so no pack sits in it unexcluded if the app dies mid-move,
then moves what older builds left in `Mob.data_dir()/packs` (per file:
rename, or copy to `.migrating`, check the size, rename into place, delete
the source; a file already in the new directory wins). Every start, not
once: a restore or a move to a new phone can drop the attribute. An
exclusion that fails is logged and the app starts anyway: a library in a
backed-up directory beats none.
`Bezalel.Study.DB.dir/0` remains the one function naming the directory; the
app support root is resolved once per run (Android needs the activity for
it). mob is pinned to the merged commit until a release carries the API.

## Consequences
An upgraded iPhone moves its packs on the first start of the new build (a
rename on one volume: instant). A pack that can't be moved stays where it
was, is logged, and is moved at the next start. Android is unchanged
(`android:allowBackup="false"`; same directory). Off device the packs stay
in `Mob.data_dir()/packs`. Return mob to Hex (`~> <release>`) once a release
includes mob#209.
