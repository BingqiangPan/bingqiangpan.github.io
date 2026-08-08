#!/bin/bash
set -euo pipefail

VERSION="3.3"
RESERVE_BYTES=$((5 * 1024 * 1024 * 1024))
NO_DATE_FOLDER="_No Data"

SCRIPT_NAME="macOS Photo Importer"

# Runtime paths and command-line mode flags.
SOURCE_DIR=""
TARGET_DIR=""
DB_DIR=""
DB_FILE=""
LOG_FILE=""
AUTO_YES=0
AUTO_ARCHIVE=0
ARCHIVE_DIR=""
START_EPOCH=0
IMPORT_PHASE_STARTED=0
LOG_WRITTEN=0

# Session counters shown in Terminal and written to Import Log.txt.
SCAN_TOTAL=0
IMPORT_COUNT=0
DUPLICATE_COUNT=0
NO_DATE_COUNT=0
FAILED_COUNT=0
IMPORT_BYTES=0
PHOTO_COUNT=0
VIDEO_COUNT=0
ARCHIVED_COUNT=0
ARCHIVE_FAILED_COUNT=0
ARCHIVE_CANDIDATE_COUNT=0

# In-memory work queues. Paths are kept only for the current run.
declare -a IMPORT_SRC=()
declare -a IMPORT_DATE=()
declare -a IMPORT_SIZE=()
declare -a IMPORT_PREHASH=()
declare -a ARCHIVE_SRC=()
declare -a ARCHIVE_REASON=()
declare -a SCAN_FILES=()
declare -a DUPLICATE_FILES=()
declare -a NO_DATE_FILES=()
declare -a FAILED_FILES=()
declare -a IMPORTED_FILES=()
declare -a ARCHIVED_FILES=()
declare -a ARCHIVED_IMPORTED_FILES=()
declare -a ARCHIVED_DUPLICATE_FILES=()
declare -a ARCHIVE_FAILED_FILES=()

# Best-effort log on unexpected failures after copying starts.
die() {
  printf '\nError: %s\n' "$1" >&2
  exit 1
}

on_exit() {
  local status="$1"

  if (( status != 0 && IMPORT_PHASE_STARTED == 1 && LOG_WRITTEN == 0 )) && [[ -n "$LOG_FILE" ]]; then
    set +e
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("Script stopped unexpectedly with exit status $status")
    write_log "$START_EPOCH" "$(date +%s)"
    LOG_WRITTEN=1
  fi
}

trap 'on_exit "$?"' EXIT

# User interface helpers.
usage() {
  cat <<EOF
$SCRIPT_NAME v$VERSION

Usage:
  ./src/photo_importer.sh
  ./src/photo_importer.sh --source SOURCE_DIR --target TARGET_DIR --yes
  ./src/photo_importer.sh --source SOURCE_DIR --target TARGET_DIR --yes --archive

Without --source and --target, the script uses Finder folder pickers.
EOF
}

notice() {
  printf '%s\n' "$1"
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) {
      b /= 1024;
      i++;
    }
    if (i == 1) {
      printf "%d %s", b, u[i];
    } else {
      printf "%.2f %s", b, u[i];
    }
  }'
}

duration_text() {
  local seconds="$1"
  local minutes=$((seconds / 60))
  local rest=$((seconds % 60))

  if (( minutes > 0 )); then
    printf '%dm%02ds' "$minutes" "$rest"
  else
    printf '%ds' "$rest"
  fi
}

sql_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}

choose_folder() {
  local prompt="$1"
  osascript \
    -e 'on run argv' \
    -e 'POSIX path of (choose folder with prompt (item 1 of argv))' \
    -e 'end run' \
    "$prompt"
}

confirm_dialog() {
  local message="$1"
  osascript \
    -e 'on run argv' \
    -e 'display dialog (item 1 of argv) buttons {"Cancel", "Start Import"} default button "Start Import" cancel button "Cancel"' \
    -e 'end run' \
    "$message" >/dev/null
}

show_done_dialog() {
  local message="$1"
  osascript \
    -e 'on run argv' \
    -e 'display dialog (item 1 of argv) buttons {"OK"} default button "OK"' \
    -e 'end run' \
    "$message" >/dev/null || true
}

confirm_archive_dialog() {
  local message="$1"
  local result
  result="$(
    osascript \
      -e 'on run argv' \
      -e 'display dialog (item 1 of argv) buttons {"Keep Source Files", "Move to archive"} default button "Keep Source Files"' \
      -e 'button returned of result' \
      -e 'end run' \
      "$message" 2>/dev/null || true
  )"

  [[ "$result" == "Move to archive" ]]
}

# Dependency and argument handling.
require_tools() {
  local missing=()
  local tool

  for tool in exiftool sqlite3 shasum cmp osascript awk sed stat df mv; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    die "Missing required tool(s): ${missing[*]}"
  fi
}

parse_args() {
  while (( "$#" > 0 )); do
    case "$1" in
      --source)
        [[ "${2:-}" ]] || die "--source requires a directory"
        SOURCE_DIR="$2"
        shift 2
        ;;
      --target)
        [[ "${2:-}" ]] || die "--target requires a directory"
        TARGET_DIR="$2"
        shift 2
        ;;
      --yes)
        AUTO_YES=1
        shift
        ;;
      --archive)
        AUTO_ARCHIVE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  if { [[ -n "$SOURCE_DIR" ]] && [[ -z "$TARGET_DIR" ]]; } || { [[ -z "$SOURCE_DIR" ]] && [[ -n "$TARGET_DIR" ]]; }; then
    die "--source and --target must be used together"
  fi
}

# Project state inside the selected target photo library.
init_paths() {
  DB_DIR="$TARGET_DIR/.photo-importer"
  DB_FILE="$DB_DIR/photo-index.sqlite3"
  LOG_FILE="$TARGET_DIR/Import Log.txt"

  mkdir -p "$DB_DIR"
}

init_db() {
  sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS media_index (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  filename TEXT NOT NULL,
  size INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  media_date TEXT NOT NULL,
  imported_at TEXT NOT NULL,
  UNIQUE(filename, size, sha256)
);

CREATE INDEX IF NOT EXISTS idx_media_filename_size
ON media_index(filename, size);

CREATE INDEX IF NOT EXISTS idx_media_hash
ON media_index(sha256);
SQL
}

# Safety guard: the importer must never scan its own target tree.
canonical_dir() {
  local path="$1"
  (cd "$path" 2>/dev/null && pwd -P)
}

validate_paths() {
  local source_real target_real

  source_real="$(canonical_dir "$SOURCE_DIR")" || die "Cannot resolve source directory: $SOURCE_DIR"
  target_real="$(canonical_dir "$TARGET_DIR")" || die "Cannot resolve target directory: $TARGET_DIR"

  if [[ "$source_real" == "$target_real" ]]; then
    die "Source and target directories cannot be the same."
  fi

  if [[ "$target_real" == "$source_real/"* ]]; then
    die "Target directory cannot be inside the source directory."
  fi

  if [[ "$source_real" == "$target_real/"* ]]; then
    die "Source directory cannot be inside the target directory."
  fi

  SOURCE_DIR="$source_real"
  TARGET_DIR="$target_real"
}

# Media type and metadata helpers.
lower_ext() {
  local path="$1"
  local name ext
  name="$(basename "$path")"
  ext="${name##*.}"
  printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}

is_supported_media() {
  local path="$1"
  local name ext
  name="$(basename "$path")"

  case "$name" in
    ._*|.DS_Store|Thumbs.db|thumbs.db)
      return 1
      ;;
  esac

  ext="$(lower_ext "$path")"

  case "$ext" in
    jpg|jpeg|heic|heif|png|tif|tiff|dng|cr2|cr3|nef|nrw|arw|srf|sr2|raf|orf|rw2|pef|srw|x3f|iiq|mos|mrw|3fr|fff|rwl|raw|mp4|mov|m4v|avi|mts|m2ts|mpg|mpeg|wmv)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_video() {
  local path="$1"
  local ext
  ext="$(lower_ext "$path")"

  case "$ext" in
    mp4|mov|m4v|avi|mts|m2ts|mpg|mpeg|wmv)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

file_size() {
  stat -f '%z' "$1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

media_date() {
  local path="$1"
  local value

  value="$(
    exiftool -s3 -d '%Y-%m-%d' \
      -DateTimeOriginal \
      -CreateDate \
      -MediaCreateDate \
      -TrackCreateDate \
      -CreationDate \
      "$path" 2>/dev/null \
    | awk 'NF { print; exit }'
  )"

  if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%s' "$value"
  fi
}

# SQLite is an accelerator. Real repeats are still confirmed against target files.
db_has_filename_size() {
  local filename="$1"
  local size="$2"
  local q_filename
  q_filename="$(sql_quote "$filename")"

  sqlite3 "$DB_FILE" "SELECT 1 FROM media_index WHERE filename = '$q_filename' AND size = $size LIMIT 1;"
}

db_has_hash() {
  local filename="$1"
  local size="$2"
  local sha="$3"
  local q_filename q_sha
  q_filename="$(sql_quote "$filename")"
  q_sha="$(sql_quote "$sha")"

  sqlite3 "$DB_FILE" "SELECT 1 FROM media_index WHERE filename = '$q_filename' AND size = $size AND sha256 = '$q_sha' LIMIT 1;"
}

target_has_same_content() {
  local _date="$1"
  local size="$2"
  local sha="$3"
  local candidate candidate_hash

  while IFS= read -r -d '' candidate; do
    if ! is_supported_media "$candidate"; then
      continue
    fi

    candidate_hash="$(sha256_file "$candidate")"
    if [[ "$candidate_hash" == "$sha" ]]; then
      return 0
    fi
  done < <(
    find "$TARGET_DIR" \
      -path "$DB_DIR" -prune -o \
      -type f \
      -size "${size}c" \
      ! -name '*.partial' \
      ! -name 'Import Log.txt' \
      -print0
  )

  return 1
}

db_insert() {
  local filename="$1"
  local size="$2"
  local sha="$3"
  local date="$4"
  local imported_at="$5"
  local q_filename q_sha q_date q_imported_at

  q_filename="$(sql_quote "$filename")"
  q_sha="$(sql_quote "$sha")"
  q_date="$(sql_quote "$date")"
  q_imported_at="$(sql_quote "$imported_at")"

  sqlite3 "$DB_FILE" \
    "INSERT OR IGNORE INTO media_index (filename, size, sha256, media_date, imported_at)
     VALUES ('$q_filename', $size, '$q_sha', '$q_date', '$q_imported_at');"
}

# Queue helpers.
add_import_candidate() {
  local src="$1"
  local date="$2"
  local size="$3"
  local prehash="$4"

  IMPORT_SRC+=("$src")
  IMPORT_DATE+=("$date")
  IMPORT_SIZE+=("$size")
  IMPORT_PREHASH+=("$prehash")
  IMPORT_BYTES=$((IMPORT_BYTES + size))
}

add_archive_candidate() {
  local src="$1"
  local reason="$2"
  ARCHIVE_SRC+=("$src")
  ARCHIVE_REASON+=("$reason")
  ARCHIVE_CANDIDATE_COUNT=$((ARCHIVE_CANDIDATE_COUNT + 1))
}

# Terminal progress display.
show_progress() {
  local current="$1"
  local total="$2"
  local phase="$3"
  local label="$4"
  local width=30
  local filled empty percent short_label

  if (( total <= 0 )); then
    return
  fi

  filled=$((current * width / total))
  empty=$((width - filled))
  percent=$((current * 100 / total))
  short_label="$label"

  if (( ${#short_label} > 38 )); then
    short_label="...${short_label: -35}"
  fi

  printf '\r%s [' "$phase"
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf '] %3d%%  %d/%d  %s' "$percent" "$current" "$total" "$short_label"
}

# Scan source, classify files, and build import/archive queues.
collect_scan_files() {
  local path
  SCAN_FILES=()

  while IFS= read -r -d '' path; do
    if is_supported_media "$path"; then
      SCAN_FILES+=("$path")
    fi
  done < <(find "$SOURCE_DIR" -path "$ARCHIVE_DIR" -prune -o -type f -print0)
}

scan_source() {
  local total i path

  notice "Finding media files..."
  collect_scan_files

  total="${#SCAN_FILES[@]}"
  notice "Scanning $total media file(s)..."

  if (( total == 0 )); then
    return
  fi

  for ((i = 0; i < total; i++)); do
    path="${SCAN_FILES[$i]}"
    show_progress "$((i + 1))" "$total" "Scanning" "$(basename "$path")"

    SCAN_TOTAL=$((SCAN_TOTAL + 1))

    local name size date same_size sha is_dup
    name="$(basename "$path")"
    size="$(file_size "$path")"
    date="$(media_date "$path")"

    if [[ -z "$date" ]]; then
      NO_DATE_COUNT=$((NO_DATE_COUNT + 1))
      NO_DATE_FILES+=("$path")
      date="$NO_DATE_FOLDER"
    fi

    same_size="$(db_has_filename_size "$name" "$size")"

    if [[ -z "$same_size" ]]; then
      add_import_candidate "$path" "$date" "$size" ""
      continue
    fi

    sha="$(sha256_file "$path")"
    is_dup="$(db_has_hash "$name" "$size" "$sha")"

    if [[ -n "$is_dup" ]] && target_has_same_content "$date" "$size" "$sha"; then
      DUPLICATE_COUNT=$((DUPLICATE_COUNT + 1))
      DUPLICATE_FILES+=("$path")
      add_archive_candidate "$path" "duplicate"
    else
      add_import_candidate "$path" "$date" "$size" "$sha"
    fi

  done

  printf '\n'
}

# Pre-check: only bytes that will actually be copied count against free space.
available_bytes() {
  df -Pk "$TARGET_DIR" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

precheck_space() {
  local available required
  available="$(available_bytes)"
  required=$((IMPORT_BYTES + RESERVE_BYTES))

  notice ""
  notice "Pre-check"
  notice "---------"
  notice "Scanned:    $SCAN_TOTAL"
  notice "To import:  ${#IMPORT_SRC[@]}"
  notice "Duplicates: $DUPLICATE_COUNT"
  notice "No date:    $NO_DATE_COUNT -> $NO_DATE_FOLDER"
  notice "New data:   $(human_bytes "$IMPORT_BYTES")"
  notice "Available:  $(human_bytes "$available")"
  notice "Reserve:    $(human_bytes "$RESERVE_BYTES")"
  notice ""

  if (( available < required )); then
    die "Not enough free space. Need $(human_bytes "$required") including reserve, available $(human_bytes "$available")."
  fi
}

# Destination naming and verified copy.
relative_target_path() {
  local date="$1"
  local filename="$2"
  printf '%s/%s' "$date" "$filename"
}

unique_destination() {
  local dir="$1"
  local filename="$2"
  local base ext candidate counter

  if [[ "$filename" == *.* ]]; then
    base="${filename%.*}"
    ext=".${filename##*.}"
  else
    base="$filename"
    ext=""
  fi

  candidate="$dir/$filename"
  counter=1

  while [[ -e "$candidate" || -e "$candidate.partial" ]]; do
    candidate="$dir/${base}-${counter}${ext}"
    counter=$((counter + 1))
  done

  printf '%s' "$candidate"
}

copy_one() {
  local src="$1"
  local date="$2"
  local size="$3"
  local prehash="$4"
  local imported_at="$5"
  local name dest_dir dest partial sha rel

  name="$(basename "$src")"
  dest_dir="$TARGET_DIR/$date"
  mkdir -p "$dest_dir"

  dest="$(unique_destination "$dest_dir" "$name")"
  partial="$dest.partial"

  if ! cp -p "$src" "$partial"; then
    rm -f "$partial"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$src :: copy failed")
    return
  fi

  if ! cmp -s "$src" "$partial"; then
    rm -f "$partial"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$src :: verification failed")
    return
  fi

  if [[ -n "$prehash" ]]; then
    sha="$prehash"
  else
    sha="$(sha256_file "$src")"
  fi

  if ! db_insert "$name" "$size" "$sha" "$date" "$imported_at"; then
    rm -f "$partial"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$src :: index update failed")
    return
  fi

  if ! mv "$partial" "$dest"; then
    rm -f "$partial"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$src :: final rename failed")
    return
  fi

  IMPORT_COUNT=$((IMPORT_COUNT + 1))
  if is_video "$src"; then
    VIDEO_COUNT=$((VIDEO_COUNT + 1))
  else
    PHOTO_COUNT=$((PHOTO_COUNT + 1))
  fi

  rel="$(relative_target_path "$date" "$(basename "$dest")")"
  IMPORTED_FILES+=("$rel")
  add_archive_candidate "$src" "imported"
}

# Copy queued files into the target library.
import_files() {
  local total="${#IMPORT_SRC[@]}"
  local imported_at
  imported_at="$(date '+%Y-%m-%d %H:%M:%S')"

  if (( total == 0 )); then
    notice "Nothing new to import."
    return
  fi

  notice ""
  notice "Importing $total file(s)..."

  local i
  for ((i = 0; i < total; i++)); do
    show_progress "$((i + 1))" "$total" "Importing" "$(basename "${IMPORT_SRC[$i]}")"
    copy_one "${IMPORT_SRC[$i]}" "${IMPORT_DATE[$i]}" "${IMPORT_SIZE[$i]}" "${IMPORT_PREHASH[$i]}" "$imported_at"
  done

  printf '\n'
}

# Optional source cleanup after files are safely imported or confirmed repeated.
archive_source_candidates() {
  local total="${#ARCHIVE_SRC[@]}"
  local i src dest reason

  if (( total == 0 )); then
    return
  fi

  mkdir -p "$ARCHIVE_DIR"
  notice ""
  notice "Moving imported or duplicate source file(s) to archive..."

  for ((i = 0; i < total; i++)); do
    src="${ARCHIVE_SRC[$i]}"
    reason="${ARCHIVE_REASON[$i]}"

    if [[ ! -f "$src" ]]; then
      ARCHIVE_FAILED_COUNT=$((ARCHIVE_FAILED_COUNT + 1))
      ARCHIVE_FAILED_FILES+=("$src :: source missing")
      continue
    fi

    dest="$(unique_destination "$ARCHIVE_DIR" "$(basename "$src")")"

    if mv "$src" "$dest"; then
      ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
      ARCHIVED_FILES+=("$dest")
      if [[ "$reason" == "imported" ]]; then
        ARCHIVED_IMPORTED_FILES+=("$dest")
      elif [[ "$reason" == "duplicate" ]]; then
        ARCHIVED_DUPLICATE_FILES+=("$dest")
      fi
    else
      ARCHIVE_FAILED_COUNT=$((ARCHIVE_FAILED_COUNT + 1))
      ARCHIVE_FAILED_FILES+=("$src :: archive move failed")
    fi
  done
}

# Import Log.txt writer.
append_named_array_to_log() {
  local title="$1"
  local array_name="$2"
  local count
  local i
  local item

  eval "count=\${#${array_name}[@]}"

  {
    printf '\n%s\n\n' "$title"
    if (( count == 0 )); then
      printf 'None\n'
    else
      for ((i = 0; i < count; i++)); do
        eval "item=\${${array_name}[$i]}"
        printf '%s\n' "$item"
      done
    fi
  } >> "$LOG_FILE"
}

write_log() {
  local start_time="$1"
  local end_time="$2"
  local elapsed=$((end_time - start_time))

  {
    printf '============================================================\n'
    printf 'Import %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Version: v%s\n' "$VERSION"
    printf '============================================================\n\n'
    printf 'Source:\n%s\n\n' "$SOURCE_DIR"
    printf 'Target:\n%s\n\n' "$TARGET_DIR"
    printf 'Scanned: %s\n' "$SCAN_TOTAL"
    printf 'Imported: %s\n' "$IMPORT_COUNT"
    printf 'Photos: %s\n' "$PHOTO_COUNT"
    printf 'Videos: %s\n' "$VIDEO_COUNT"
    printf 'Duplicates: %s\n' "$DUPLICATE_COUNT"
    printf 'No date: %s\n' "$NO_DATE_COUNT"
    printf 'Failed: %s\n' "$FAILED_COUNT"
    printf 'Archived: %s\n' "$ARCHIVED_COUNT"
    printf 'Archive candidates: %s\n' "$ARCHIVE_CANDIDATE_COUNT"
    printf 'Archive failed: %s\n' "$ARCHIVE_FAILED_COUNT"
    printf 'New data: %s\n' "$(human_bytes "$IMPORT_BYTES")"
    printf 'Duration: %s\n' "$(duration_text "$elapsed")"
  } >> "$LOG_FILE"

  append_named_array_to_log "Imported Files" "IMPORTED_FILES"
  append_named_array_to_log "Duplicate Files" "DUPLICATE_FILES"
  append_named_array_to_log "No Date Files" "NO_DATE_FILES"
  append_named_array_to_log "Failed Files" "FAILED_FILES"
  append_named_array_to_log "Archived Source Files" "ARCHIVED_FILES"
  append_named_array_to_log "Archived Imported Source Files" "ARCHIVED_IMPORTED_FILES"
  append_named_array_to_log "Archived Duplicate Source Files" "ARCHIVED_DUPLICATE_FILES"
  append_named_array_to_log "Archive Failed Files" "ARCHIVE_FAILED_FILES"

  printf '\n' >> "$LOG_FILE"
}

# Main workflow.
main() {
  local start_time end_time message archive_message done_message
  start_time="$(date +%s)"
  START_EPOCH="$start_time"

  notice "$SCRIPT_NAME v$VERSION"
  notice ""

  parse_args "$@"
  require_tools

  if [[ -z "$SOURCE_DIR" ]]; then
    SOURCE_DIR="$(choose_folder "Choose the source folder, for example the SD card DCIM folder")"
    TARGET_DIR="$(choose_folder "Choose the target photo library folder")"
  fi

  [[ -d "$SOURCE_DIR" ]] || die "Source directory does not exist: $SOURCE_DIR"
  [[ -d "$TARGET_DIR" ]] || die "Target directory does not exist: $TARGET_DIR"
  SOURCE_DIR="${SOURCE_DIR%/}"
  TARGET_DIR="${TARGET_DIR%/}"
  validate_paths
  ARCHIVE_DIR="$SOURCE_DIR/archive"

  init_paths
  init_db
  scan_source
  precheck_space

  message="$(printf 'Scanned files: %s\nReady to import: %s\nRepeated files: %s\nNo date: %s, imported to %s\nNew data: %s\n\nStart import?' \
    "$SCAN_TOTAL" \
    "${#IMPORT_SRC[@]}" \
    "$DUPLICATE_COUNT" \
    "$NO_DATE_COUNT" \
    "$NO_DATE_FOLDER" \
    "$(human_bytes "$IMPORT_BYTES")")"
  if (( AUTO_YES == 0 )); then
    confirm_dialog "$message"
  fi

  IMPORT_PHASE_STARTED=1
  import_files

  if (( AUTO_ARCHIVE == 1 && ARCHIVE_CANDIDATE_COUNT > 0 )); then
    archive_source_candidates
  elif (( AUTO_YES == 0 && ARCHIVE_CANDIDATE_COUNT > 0 )); then
    archive_message="$(printf 'Import finished.\n\nImported: %s\nPhotos: %s\nVideos: %s\nRepeated files: %s\nNo date: %s, imported to %s\nFailed: %s\nCan move to archive: %s\n\nMove successfully imported or confirmed repeated source files to the source archive folder?\n%s' \
      "$IMPORT_COUNT" \
      "$PHOTO_COUNT" \
      "$VIDEO_COUNT" \
      "$DUPLICATE_COUNT" \
      "$NO_DATE_COUNT" \
      "$NO_DATE_FOLDER" \
      "$FAILED_COUNT" \
      "$ARCHIVE_CANDIDATE_COUNT" \
      "$ARCHIVE_DIR")"

    if confirm_archive_dialog "$archive_message"; then
      archive_source_candidates
    fi
  fi

  end_time="$(date +%s)"
  write_log "$start_time" "$end_time"
  LOG_WRITTEN=1

  notice ""
  notice "Done."
  notice "Imported: $IMPORT_COUNT"
  notice "Photos: $PHOTO_COUNT"
  notice "Videos: $VIDEO_COUNT"
  notice "Duplicates: $DUPLICATE_COUNT"
  notice "No date: $NO_DATE_COUNT -> $NO_DATE_FOLDER"
  notice "Failed: $FAILED_COUNT"
  notice "Archive candidates: $ARCHIVE_CANDIDATE_COUNT"
  notice "Archived: $ARCHIVED_COUNT"
  notice "Log: $LOG_FILE"

  if (( AUTO_YES == 0 )); then
    done_message="$(printf 'Import finished.\n\nImported: %s\nPhotos: %s\nVideos: %s\nRepeated files: %s\nNo date: %s, imported to %s\nFailed: %s\nArchive candidates: %s\nMoved to archive: %s' \
      "$IMPORT_COUNT" \
      "$PHOTO_COUNT" \
      "$VIDEO_COUNT" \
      "$DUPLICATE_COUNT" \
      "$NO_DATE_COUNT" \
      "$NO_DATE_FOLDER" \
      "$FAILED_COUNT" \
      "$ARCHIVE_CANDIDATE_COUNT" \
      "$ARCHIVED_COUNT")"

    show_done_dialog "$done_message"
  fi
}

main "$@"
