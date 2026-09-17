# Offline reference resolution via the OpenAlex snapshot

## Why this exists

OpenAlex's `title.search` API endpoint **times out on a large fraction of
queries** — verified empirically: real conference reference titles repeatedly
timed out at 25–30 s, regardless of the client (openalexR *or* direct httr2).
Resolving ~43,000 references this way is infeasible. Offline matching against a
local copy of OpenAlex has **no timeout** (a miss is instant), so it is the
robust path. DOI lookups via the API remain free and fast and are still used.

This pipeline is scripts **19 → 20 → 21**. It produces the same
`16_reference_matches*.csv` outputs as the API script 16, so the downstream
endogeneity scripts (17, 18) run unchanged.

## The data

* The OpenAlex **works** snapshot lives in a free public S3 bucket
  (`s3://openalex/data/works/`, accessed with `--no-sign-request`, no AWS
  account, **$0**).
* It is gzip JSON-Lines, one work per line, ~**639 GB compressed across 2,128
  part files**, partitioned by `updated_date` (NOT by subject).
* Because partitions are by date, topic filtering requires **streaming all of
  it** — transfer is ~15–30 h on a home connection. The job is **resumable**.

## Disk & storage (read before running)

Script 19 streams one ~2 GB part at a time, filters it, then **deletes the raw
part** — so you do **NOT** need 639 GB locally. **Peak disk ≈ 2–4 GB** (one part
+ the growing compact index). Only the bytes pass through; only the small index
persists.

**Write everything locally during the run; archive to Synology at the end.**

* **`OA_TMP_DIR`** (transient `.gz` parts) → **local disk**. Never a cloud-sync
  folder: the client would upload all 639 GB as it streams through.
* **`OA_INDEX_DIR`** (the live index) → **local disk too**. The index is appended
  thousands of times; a sync client would re-upload the whole growing file on
  every append, and can race/lock it mid-write.
* **`OA_ARCHIVE_DIR`** (optional) → the **Synology folder** is fine here. The
  finished index + resume log are copied here **once at the end of each run** —
  safe backup, no during-run thrashing. Set to empty to skip.

Defaults: `~/oa_snapshot_tmp`, `~/oa_snapshot_index`, and the Synology
`openalex_index` folder for the archive. Override via the env vars above.

## Batching (the 639 GB doesn't have to be one sitting)

The job is **resumable** (a `.done_parts` log) and can run in controlled batches:

* **`MAX_PARTS=N`** — process at most N new parts this run, then stop cleanly.
  Re-run to continue from where it stopped. E.g. `MAX_PARTS=300` per night.
* Or just **Ctrl-C anytime** — the current part is left un-done and retried; the
  index is never left half-written (each part is appended only on success).

Note `MAX_PARTS` caps *parts*, not bytes — part sizes vary (a few MB to ~2 GB),
so a 300-part batch may transfer anywhere from a few GB to tens of GB.

## Two variants: narrow (in-RAM) vs all-works (DuckDB)

A Lit+Linguistics-only index (~7M works) matched only ~5% of references — most
conference citations point OUTSIDE those subfields. A live-API ceiling test
showed ~50% of the no-matches DO exist in OpenAlex, just in other fields. So the
recommended route is the **all-works index** queried with **DuckDB** (which
streams from Parquet and spills to disk, so a ~250M-row index works on bounded
RAM — the old in-RAM scripts 20/21 would OOM at that scale).

### A) All-works index + DuckDB matcher (recommended)

```bash
# 1. Stream the WHOLE snapshot (no subfield filter), in nightly batches.
MAX_PARTS=300 bash R/19_download_filter_snapshot.sh
#    Re-run until it prints "ALL parts processed". This index is large (tens of
#    GB TSV); ensure scratch has room.

# 2. Convert TSV -> Parquet (adds title_norm). NO script 20 — DuckDB reads parquet.
Rscript R/20a_tsv_to_parquet.R

# 3. Match references offline with DuckDB (DOI -> exact title -> fuzzy JW).
Rscript R/21_match_references_duckdb.R
#    On Habrok set TMPDIR=/scratch/$USER/duckdb_tmp so spills don't fill $HOME.

# 4. Cited-work countries — read from the LOCAL parquet (no API; script 17 was
#    rewritten to join matched ids to the index's `countries` column).
Rscript R/17_conference_cited_countries.R

# 5. Endogeneity, split by venue group to avoid the regional-conference confound.
#    The headline result holds in the ADHO-global subset alone.
VENUE_GROUP=ADHO-global Rscript R/18_conference_endogeneity.R   # -> *_adho outputs
VENUE_GROUP=regional    Rscript R/18_conference_endogeneity.R   # -> *_regional outputs
VENUE_GROUP=all         Rscript R/18_conference_endogeneity.R   # -> unsuffixed outputs

# 6. Figures (defaults to the ADHO-global subset; override with CONF_SUFFIX).
Rscript R/06b_conference_comparison.R
```

Result on the all-works index (snapshot ~June 2026), scoring on the cited-work
**title alone** (see below): **11,645 accepted matches (26.7%** of ~43.6k
references) — DOI 2,096, exact-title 8,356, fuzzy 1,193 (all >= 0.95). Stripping
the trailing author/year from the reference before matching moved thousands of
references from fuzzy into the *exact* tier, which is the bulk of the gain over
the earlier title+author+year run (7,523 / 17.2%). Cited-work country coverage is
**43%**. Endogeneity is higher at the ADHO conference (~42% any-overlap) than in
DH journals (which decline over time), and this survives the venue split.

Per-series note: although script 13 tags a finer `venue_series` (each regional
series kept separate, B1 rule), only **ADHO-global** (~4,520 resolved citations)
and **DHd** (~331) clear any usable citation volume — every other regional series
resolves to zero edges. The per-series breakdown is therefore effectively
ADHO-global vs DHd (≈42% vs ≈40%); this is a coverage limit, unchanged by the
series floor (`SERIES_MIN_CITATIONS`, default 50).

### On Habrok (three SLURM jobs, in order)

Everything runs on the cluster — `/scratch` for data, the arrow R module for
matching, a Python venv with `awscli` for streaming. All data paths point at
`/scratch/$USER` (home is only ~20 GB).

```bash
# 1. STREAM the snapshot (CPU+network, batched). Re-submit until it reports
#    "ALL parts processed" — it resumes via .done_parts each time.
sbatch habrok/stream_snapshot.slurm        # runs R/19, MAX_PARTS=400/job by default

# 2. TSV -> Parquet  (needs RAM; arrow module)
sbatch habrok/build_index.slurm            # runs R/20a only (no script 20 at this scale)

# 3. MATCH with DuckDB  (sets TMPDIR=/scratch so spills don't fill $HOME)
sbatch habrok/match_references.slurm       # runs R/21_match_references_duckdb.R
```

Prerequisites on Habrok (one-time):
* `awscli` from the cluster module: `module load awscli/2.15.2-GCCcore-12.2.0`
  (the stream SLURM script loads this; verify the name with `module avail awscli`).
* R packages in `$R_LIBS_USER`: `arrow` comes from the `arrow-R` module; install
  `duckdb, DBI, data.table, stringi, stringdist, tidyverse` once (build duckdb
  with `MAKEFLAGS=-j8` in an `srun` session — it compiles for a while).
* Edit `PROJECT_DIR` at the top of each SLURM script to your repo path.

Note: streaming needs network egress from compute nodes. If Habrok blocks
outbound S3 from the `regular` partition, run `R/19` from a login node or a
node type that permits egress (check with the HPC docs / a short test job).

### B) Narrow in-RAM index (small/quick, low recall)

For a small subfield-filtered index that fits in RAM, the original path still
works: `SUBFIELD_FILTER="1208,1203" bash R/19_...` → `Rscript R/20_build_title_index.R`
→ `Rscript R/21_match_references_offline.R`. Use only if you deliberately want a
precise, narrow subset.

## Matching logic (script 21_match_references_duckdb.R)

Tiered. **All title matching is on the title ALONE** — the cited work's title is
parsed out of the reference (AnyStyle `title` field, or the bare citation for
XML/TEI) and the trailing author/year is dropped before normalising. Including
the author/year tail depressed the Jaro–Winkler score of genuine matches and
pushed them out of the exact tier; scoring title-only recovers them.

1. **DOI join** — exact, confidence 1.00.
2. **Exact normalised-title** — confidence 1.00. (Same `norm_title()`: strips
   URLs/boilerplate, de-accents, keeps alphanumerics.) After the title-only
   change this tier absorbs most matches (8,356) that previously scored as fuzzy.
3. **Fuzzy title** — candidates blocked on a title key, scored with DuckDB's
   built-in `jaro_winkler_similarity`.

### Calibrated thresholds (precision-first) — important

Manual inspection of a stratified sample of the fuzzy matches showed that the
mid band is dominated by **COINCIDENTAL word-overlap** (wrong works that share a
few tokens). Genuine fuzzy matches against a *correct* index score ~0.95+. We
therefore set:

* **≥ 0.95 → auto-accept** (reliable)
* **0.85–0.95 → REVIEW band** — written to `16_reference_matches_review.csv`,
  sorted best-first, with the matched OpenAlex title (`oa_title`) next to the
  reference so each row can be eyeballed. (Widened down from 0.93 so the manual
  review can rescue borderline-but-real matches; nothing in this band is counted
  until reviewed.)
* **< 0.85 → discarded** (NOT recorded as a match)

DOI and exact-title matches are always accepted regardless. This prioritises
**precision over recall**: a false citation silently corrupts the country-level
endogeneity numbers, whereas a missed citation only reduces sample size (a stated
limitation). The all-works index raises recall the right way — when the correct
work IS in the index it scores ~1.0 and lands in auto-accept, rather than a
coincidental wrong work scoring in the discarded band.

### Reference-quality guards (before matching)

* **bad-title guard:** skip prose/abstract dumps and lowercase-start fragments;
  XML refs (full citation strings) get a relaxed guard (only empty / >500 char).
* **`too_short_fragment` gate:** drop titles with < 4 words — residual AnyStyle
  fragments that match only by coincidence.
* **Pre-segmentation (script 15b):** txt reference blocks are split one-reference-
  per-line before AnyStyle (strip leading numbering; merge only clearly-wrapped
  lowercase/connective continuations). This cut lowercase-start fragment titles
  ~2,565 → ~244. It is imperfect: a continuation line starting with a capital can
  still be split, so ~18% of titles remain < 4 words (caught by the gate above).

## Coverage caveat (state this in the paper)

The index is built only from the **chosen subfields** (script 19's
`SUBFIELD_FILTER`). A reference whose cited work lies *outside* those subfields
will not be found offline and is recorded as "no match". This is the
precision/recall trade of the topic filter:

* **Lit + Linguistics only** → small index, high precision, misses cross-field
  citations (e.g. a DH paper citing a computer-science or history work).
* **All titled works** → ~250M works, large index, maximal recall.

To widen coverage later you must re-stream the snapshot with a broader
`SUBFIELD_FILTER`: delete `.done_parts` (and the old `works_index.tsv`) so all
parts are re-processed under the new filter. There is no way to add subfields
without re-streaming, because each part was filtered as it passed through.

## Reproducibility

* The snapshot is refreshed quarterly; **record the date you downloaded it**, as
  matches are valid "as of" that snapshot.
* Everything after the download is deterministic and offline.
* Paths are env-configurable so they aren't hard-coded to one machine:
  `OA_TMP_DIR` (local scratch), `OA_INDEX_DIR` (local live index),
  `OA_ARCHIVE_DIR` (end-of-run backup copy, e.g. Synology).
