# Photo Importer

A small macOS importer for getting camera files safely into a plain folder-based photo library.

It is not a photo manager and not a sync tool. Its job is simple:

```text
source folder -> verified copy -> dated folders in target library
```

## What It Does

- Choose source and target folders with Finder.
- Read media dates with ExifTool.
- Import to `YYYY-MM-DD/`; unknown dates go to `_No Data/`.
- Support common photo and video formats.
- Ignore `.DS_Store`, `._*`, and `Thumbs.db`.
- Use SQLite as a fast import index.
- Confirm repeats with `filename + size + sha256`, then verify real target content.
- Copy through `.partial`, verify with `cmp`, then finalize.
- Keep at least 5 GiB free on the target disk.
- Rename same-name different-content files, for example `IMG_0001-1.CR3`.
- Write `Import Log.txt` in the target folder.
- Optionally move imported or confirmed repeated source files to `source/archive/`.

## What It Does Not Do

- It does not delete source files unless you explicitly choose archive after import.
- It does not delete, mirror, or sync the target folder.
- It does not overwrite existing target files.
- It does not replace Lightroom, Photos, Capture One, Bridge, or FreeFileSync.
- It does not manage ratings, keywords, previews, edits, or catalogs.

## Use

Double-click:

```text
Photo Importer v3.4.command
```

Then:

1. Select the source folder, such as an SD card `DCIM`.
2. Select the target photo library folder.
3. Review the pre-check summary.
4. Import.
5. Optionally move handled source files to `archive/`.

## Output

```text
Photos/
├── 2026-04-03/
│   └── P4030048.ORF
├── _No Data/
│   └── unknown-date-file.jpg
├── Import Log.txt
└── .photo-importer/
    └── photo-index.sqlite3
```

Do not edit `.photo-importer/photo-index.sqlite3` manually.

## Archive Meaning

`source/archive/` means:

```text
This source file has been handled.
```

Files moved there are either:

- newly imported successfully, or
- confirmed repeated because the same content already exists in target.

Failed files are not archived. Future scans skip `archive/`.

## macOS Warning

If macOS says it cannot verify the script, remove the quarantine flag:

```sh
xattr -d com.apple.quarantine ~/Desktop/Photo\ Importer\ v3.4.command
```

If the file is elsewhere:

```sh
xattr -d com.apple.quarantine "/path/to/Photo Importer v3.4.command"
```

You can also right-click the file in Finder, choose `Open`, then confirm.

## Boundaries

- Keep source and target separate; the script blocks same or nested folders.
- Do not run while cloud sync is half-finished.
- Keep a separate backup of the photo library.
- Treat this as an importer, not a permanent verification system.

## Requirement

Install ExifTool:

```sh
brew install exiftool
```

## Version History

### v3.4

- Fix first-run SQLite initialization on some exFAT external drives.

### v3.3

- Add Finder selection, ExifTool date reading, dated import folders, SQLite repeat checks, verified copy, import log, progress display, and optional source archive.
