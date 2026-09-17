#!/usr/bin/env bash
# =============================================================================
# 19_download_filter_snapshot.sh
# -----------------------------------------------------------------------------
# Stream the FREE OpenAlex S3 snapshot of WORKS and extract a compact local index
# for offline reference matching — without ever storing the full 330 GB.
#
# WHY OFFLINE: OpenAlex's title-search API endpoint times out on a large fraction
# of queries (verified: real reference titles time out at 25s). Offline title
# matching against a local index has NO timeout — a miss is instant. This is the
# robust way to resolve ~43k conference references.
#
# HOW IT KEEPS DISK SMALL: the snapshot is gzip JSON-Lines, one work per line,
# split into many <2 GB part files. We download ONE part at a time, stream it
# through a Python filter that keeps only the fields we need, append to a TSV
# shard, then DELETE the raw part. Peak disk ≈ one part (~2 GB) + the growing
# (compact) index, not the whole snapshot.
#
# FIELDS KEPT per work: id, doi, title, publication_year, author country codes
# (';'-joined), and primary_topic.subfield.id (for optional filtering).
#
# COST: $0 — S3 is accessed with --no-sign-request (no AWS account needed).
#
# SCALE (verified): the works snapshot is ~639 GB compressed across 2,128 part
# files. We must STREAM all of it (partitions are by update-date, not subject),
# so transfer is ~15-30h on a home connection. The job is RESUMABLE — safe to
# stop/restart; it skips parts already processed.
#
# STORAGE SPLIT (important):
#   * TMP_DIR holds one ~2 GB part at a time, then deletes it. Put this on LOCAL
#     disk. Do NOT put it inside a cloud-sync folder (Dropbox/Synology/iCloud) —
#     the sync client would try to upload all 639 GB as it streams through!
#   * INDEX_DIR holds the final compact index (small). This is safe to put in a
#     synced/backed-up folder.
#
# PREREQUISITES:
#   - awscli  (pip install awscli)   - python3
# OUTPUT:
#   $INDEX_DIR/works_index.tsv     (compact index; one titled work per line)
#   $INDEX_DIR/.done_parts         (resume log: parts already processed)
#   (optionally copied to $ARCHIVE_DIR at the end of a run)
#
# Run (edit the paths for your machine first):
#   bash R/19_download_filter_snapshot.sh
#   SUBFIELD_FILTER="1208,1203" bash R/19_download_filter_snapshot.sh   # DH-only
#   MAX_PARTS=200 bash R/19_download_filter_snapshot.sh                 # batch of 200
# =============================================================================
set -euo pipefail

# --- storage paths -----------------------------------------------------------
# IMPORTANT: write EVERYTHING locally during the run. Do NOT point TMP_DIR or
# INDEX_DIR at a cloud-sync folder (Synology/Dropbox/iCloud):
#   * TMP_DIR would make the sync client upload all 639 GB as it streams through.
#   * INDEX_DIR is APPENDED thousands of times; a sync client would re-upload the
#     whole growing file on every append, and can race/lock it mid-write.
# Instead, build locally, then (optionally) copy the finished index to the synced
# folder ONCE at the end via ARCHIVE_DIR.
TMP_DIR="${OA_TMP_DIR:-$HOME/oa_snapshot_tmp}"          # transient .gz parts (local)
INDEX_DIR="${OA_INDEX_DIR:-$HOME/oa_snapshot_index}"    # live index (local!)
# One-shot backup copy after each run. Safe to be the Synology folder. Empty = skip.
ARCHIVE_DIR="${OA_ARCHIVE_DIR:-/Users/fedor/Library/CloudStorage/SynologyDrive-sync/openalex_index}"

INDEX="$INDEX_DIR/works_index.tsv"
DONE_LOG="$INDEX_DIR/.done_parts"
mkdir -p "$TMP_DIR" "$INDEX_DIR"
touch "$DONE_LOG"

echo "Temp (local):   $TMP_DIR"
echo "Index (local):  $INDEX_DIR"
echo "Archive (copy at end): ${ARCHIVE_DIR:-<none>}"

# Optional: restrict to DH-adjacent subfields (comma-separated OpenAlex subfield
# numbers, e.g. "1208,1203" = Literature + Language/Linguistics). Empty = keep
# every work that has a title. Smaller filter => much smaller index & faster.
SUBFIELD_FILTER="${SUBFIELD_FILTER:-}"

# Optional: process at most this many NEW parts this run, then stop cleanly.
# Lets you do the 2,128-part job in controlled batches (e.g. 200/night). The
# resume log means the next run continues from where this one stopped.
# 0 (default) = no cap (process everything not yet done).
MAX_PARTS="${MAX_PARTS:-0}"

# The OpenAlex bucket is in us-east-1. On some hosts `aws` auto-resolves a wrong
# region endpoint for `cp` (e.g. "s3.nov.amazonaws.com"), which fails to connect
# even though `ls` works. Forcing the region fixes it. Override via OA_AWS_REGION.
AWS_REGION="${OA_AWS_REGION:-us-east-1}"
AWS_FLAGS=(--no-sign-request --region "$AWS_REGION")

echo "=== OpenAlex snapshot stream-filter ==="
echo "Subfield filter: ${SUBFIELD_FILTER:-<none: all titled works>}"

# Write the TSV header once.
if [ ! -s "$INDEX" ]; then
  printf 'id\tdoi\ttitle\tyear\tcountries\tsubfield\n' > "$INDEX"
fi

# --- the per-line filter (Python; reads gz-decompressed JSONL on stdin) -------
read -r -d '' FILTER_PY <<'PYEOF' || true
import sys, json, os
keep = os.environ.get("SUBFIELD_FILTER", "").strip()
keep_set = set(s.strip() for s in keep.split(",") if s.strip()) if keep else None

def clean(s):
    if not s: return ""
    return str(s).replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        w = json.loads(line)
    except Exception:
        continue
    title = w.get("title") or w.get("display_name")
    if not title:                      # no title -> useless for title matching
        continue
    # subfield filter (primary_topic.subfield.id like ".../subfields/1208")
    sub = ""
    pt = w.get("primary_topic") or {}
    subf = (pt.get("subfield") or {}).get("id") or ""
    if subf:
        sub = subf.rstrip("/").split("/")[-1]
    if keep_set is not None and sub not in keep_set:
        continue
    wid = (w.get("id") or "").rstrip("/").split("/")[-1]
    doi = w.get("doi") or ""
    if doi:
        doi = doi.replace("https://doi.org/", "").lower()
    year = w.get("publication_year") or ""
    # author country codes (full counting), de-duplicated
    ccs = []
    for a in (w.get("authorships") or []):
        for c in (a.get("countries") or []):
            if c: ccs.append(c.upper())
        for inst in (a.get("institutions") or []):
            cc = inst.get("country_code")
            if cc: ccs.append(cc.upper())
    countries = ";".join(sorted(set(ccs)))
    sys.stdout.write("\t".join([wid, clean(doi), clean(title), str(year),
                                countries, sub]) + "\n")
PYEOF

# --- preflight: required tools -----------------------------------------------
for tool in aws python3 gzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH." >&2
    if [ "$tool" = "aws" ]; then
      echo "  Install the AWS CLI:  brew install awscli   (then: aws --version)" >&2
      echo "  If installed but not found, check 'which aws' and add it to PATH." >&2
    fi
    exit 1
  fi
done

# --- list all work part files from the manifest ------------------------------
echo "Fetching works file list from S3..."
PARTS=$(aws s3 ls s3://openalex/data/works/ --recursive "${AWS_FLAGS[@]}" \
        | awk '{print $4}' | grep '\.gz$' || true)
N_PARTS=$(echo "$PARTS" | grep -c . || true)
echo "Found $N_PARTS part files."

# Guard: if listing failed we must NOT proceed (and must NOT report success).
if [ "$N_PARTS" -eq 0 ]; then
  echo "ERROR: found 0 part files. The S3 listing failed (network? aws config?)." >&2
  echo "  Test manually:  aws s3 ls s3://openalex/data/works/ --no-sign-request" >&2
  exit 1
fi

i=0            # position in the full list
processed=0    # NEW parts processed this run (for the MAX_PARTS cap)
for key in $PARTS; do
  i=$((i+1))
  if grep -qxF "$key" "$DONE_LOG"; then
    continue                                   # already processed (resume)
  fi
  # Honour the per-run batch cap.
  if [ "$MAX_PARTS" -gt 0 ] && [ "$processed" -ge "$MAX_PARTS" ]; then
    echo ">>> MAX_PARTS=$MAX_PARTS reached for this run. Stopping cleanly; re-run to continue."
    break
  fi
  # Progress: print only every 50 parts to keep the log small over a long run.
  if [ $(( i % 50 )) -eq 0 ]; then
    echo "[$i/$N_PARTS] processed=$processed  $(date '+%H:%M:%S')"
  fi
  local_gz="$TMP_DIR/part_$$.gz"               # unique per process
  tmp_out="$TMP_DIR/out_$$.tsv"
  # Download THEN filter, each guarded so a single failure skips the part rather
  # than killing the whole job (set -e would otherwise abort on any non-zero).
  # Retry the download a couple of times for transient S3 errors. Failures are
  # rare and worth seeing, so keep those messages (they tag the offending key).
  dl_ok=false
  for attempt in 1 2 3; do
    if aws s3 cp "s3://openalex/$key" "$local_gz" "${AWS_FLAGS[@]}" 2>>"$INDEX_DIR/aws_errors.log"; then
      dl_ok=true; break
    fi
    sleep 5
  done
  if ! $dl_ok; then
    echo "  !! download failed after retries: $key (skipping)"
    rm -f "$local_gz"; continue
  fi
  # stream: decompress -> filter -> temp file, then append to the index on success
  if SUBFIELD_FILTER="$SUBFIELD_FILTER" gzip -dc "$local_gz" \
       | python3 -c "$FILTER_PY" > "$tmp_out" 2>>"$INDEX_DIR/filter_errors.log"; then
    cat "$tmp_out" >> "$INDEX"
    echo "$key" >> "$DONE_LOG"                 # mark done ONLY after a clean append
    processed=$((processed+1))
  else
    echo "  !! filter failed: $key (skipping; retries next run)"
  fi
  rm -f "$local_gz" "$tmp_out"                 # free disk immediately
done

n_done=$(grep -c . "$DONE_LOG" || true)
echo "=== run complete. Parts done so far: $n_done / $N_PARTS ==="
echo "Index: $INDEX"
wc -l "$INDEX" || true

# --- one-shot archive copy to the synced/backup folder -----------------------
if [ -n "${ARCHIVE_DIR:-}" ]; then
  mkdir -p "$ARCHIVE_DIR"
  echo "Copying index + resume log to archive: $ARCHIVE_DIR"
  cp -f "$INDEX" "$ARCHIVE_DIR/" && cp -f "$DONE_LOG" "$ARCHIVE_DIR/.done_parts"
  echo "Archive copy complete."
fi

if [ "$n_done" -lt "$N_PARTS" ]; then
  echo "NOT finished ($((N_PARTS - n_done)) parts remain). Re-run this script to continue."
else
  echo "ALL parts processed. Next: Rscript R/20_build_title_index.R"
fi
