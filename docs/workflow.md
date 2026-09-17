# Workflow tracker — DH citation endogeneity

> **Purpose.** This is the *living* operational record of the pipeline as actually
> built, kept separate from `research_plan.md` (the original pre-implementation
> design). When you add or change a script, parameter, or result, update this file.
>
> Last updated: 2026-09-17. Snapshot used for offline matching: ~June 2026.

---

## 1. Two corpora, two pipelines

The project compares geographic citation endogeneity in two bodies of DH work:

1. **Journal corpus** — works from the Spinaci et al. DH journal list plus
   keyword-identified works, retrieved from the OpenAlex **API**. Scripts `00`–`12`.
2. **Conference corpus** — the *Index of DH Conferences* (CMU) relational extract,
   with references recovered from abstract full text and resolved against an
   **offline OpenAlex snapshot**. Scripts `13`–`21`.

Both produce the *same* endogeneity metrics (any-overlap / majority self-citation
rate, Shannon entropy, HHI, expected-vs-observed null model, permutation test) so
results can be read side by side. Output column layouts are deliberately aligned
(e.g. conference `18_*` mirrors journal `05_*`).

---

## 2. Script map

> **Removed 2026-09-17 (repo cleanup).** Superseded or diagnostic scripts were
> deleted rather than kept: the API reference matcher (`16`, `16b`) and the
> narrow in-RAM index variants (`20`, `21_match_references_offline`) — replaced by
> `20a` + `21_match_references_duckdb`; the comparator-field pipeline (`04`, `05`)
> and the country-presence linkage (`14`), neither used in the EADH 2026 paper;
> and the review helpers (`add_matched_titles`, `inspect_*`, `check`). Their
> intermediate outputs (`14_*`, `*_with_titles`, `*_old`, `.bak`) went with them.

### Journal pipeline (OpenAlex API)

| Script | Produces | Notes |
|--------|----------|-------|
| `00_setup.R` | renv + dependencies | one-time |
| `01_build_dh_corpus.R` | `02_dh_corpus*.rds/csv`, `01_source_ids.csv` | journal + keyword retrieval, dedup, `dh_level` flags |
| `02_fetch_cited_works.R` | `04_cited_works.csv/rds` | batch-fetch country data for referenced works; checkpointed |
| `03_endogeneity_analysis.R` | `05`–`10`, `12` | metrics, null model, permutation test, bridge scholars, temporal tables |
| `06_visualizations.R` | `fig1`–`fig7` | all journal figures (incl. fig3 temporal) |
| helpers/`country_regions.R` | — | ISO alpha-2 → continent/region map |

### Conference pipeline (offline snapshot)

| Script | Produces | Notes |
|--------|----------|-------|
| `13_load_conference_data.R` | `13_conf_authorships.csv`, `13_conf_works.csv` | joins CMU relational tables → countries; tags `venue_group` + `venue_series` |
| `15_extract_conference_references.R` | `15_conf_references.csv` | pull reference strings (XML/TEI + txt) from `works.full_text` |
| `15b_parse_references_anystyle.R` | `15b_parsed_references.csv` | pre-segment txt blocks, parse with AnyStyle (Ruby); committed so collaborators skip Ruby |
| `15c_add_language_columns.R` | language columns | — |
| `17_conference_cited_countries.R` | `17_conf_cited_works.csv`, `17_conf_citation_edges.csv` | cited-work countries read from LOCAL parquet (no API) |
| `18_conference_endogeneity.R` | `18_conf_*` (per venue group + per series) | endogeneity mirroring `05`; venue-group and per-series breakdowns |
| `06b_conference_comparison.R` | `fig8`–`fig10b` | conference-vs-journal figures |

### Offline snapshot build + matching (run on Habrok)

| Script | Produces | Notes |
|--------|----------|-------|
| `19_download_filter_snapshot.sh` | streamed/filtered snapshot index | streams S3 (`--no-sign-request`, region `us-east-1`); resumable via `.done_parts`; `MAX_PARTS` caps per run |
| `20a_tsv_to_parquet.R` | `works_index_parquet/` | chunked, resumable TSV→Parquet; adds `title_norm` |
| `21_match_references_duckdb.R` | `16_reference_matches.csv`, `_review.csv` | **primary** matcher: DOI → exact-title → fuzzy JW, via DuckDB over parquet |

### Habrok SLURM jobs (run order)

```bash
sbatch habrok/stream_snapshot.slurm   # runs 19 — re-submit until "ALL parts processed"
sbatch habrok/build_index.slurm       # runs 20a (TSV → Parquet)
sbatch habrok/match_references.slurm   # runs 21_match_references_duckdb.R
```

`/scratch/$USER` holds the data (home is ~20–50 GB); the arrow R module supplies
`arrow`; `duckdb` etc. are installed once in `$R_LIBS_USER`. Edit `PROJECT_DIR`
at the top of each SLURM script.

---

## 3. Run order (end to end)

```
# Journal corpus
01 → 02 → 03           (core sequential)
06                     (figures; reads 03)

# Conference corpus
13 → 15 → 15b → 15c    (load + references)
   → [Habrok: 19 → 20a → 21]   (offline match → 16_reference_matches.csv)
17 → 18                (cited countries → endogeneity)
06b                    (figures)
```

---

## 4. Key parameters & conventions

| Parameter | Where | Value / meaning |
|-----------|-------|-----------------|
| `DH_CORPUS_FILTER` | env, script 03 | corpus tier: `exclusively` / `core` / `all` (default). Sets output suffix. |
| `VENUE_GROUP` | env, script 18 | `ADHO-global` / `regional` / `all`. Output suffix `_adho` / `_regional` / none. |
| `CONF_SUFFIX` | env, script 06b | which conference subset to plot (default `_adho`). |
| `N_PERMUTATIONS` | env, script 03 | permutation iterations (default 1000; set low for quick non-permutation reruns). |
| `MIN_CITATIONS_THRESHOLD` | scripts 03/18 | 100-citation floor for country-level analysis + permutation test. |
| `SERIES_MIN_CITATIONS` | script 18 | 50-citation floor for the **per-series** breakdown only (does not affect country test). |
| `TOP_N_COUNTRIES` | script 03 | 15 — used ONLY for convergence slopes (`10`) and the mixed model, **not** for `07`/fig3 (see §6). |
| `OA_INDEX_DIR`, `TMPDIR`, `DUCKDB_MEM_LIMIT` | env, script 21 | parquet index location, DuckDB spill dir, memory cap (default 40 GB). |
| Temporal window | scripts 03/18 | 2007–2025. |
| Country codes | all | ISO 3166-1 alpha-2, uppercase; `;`-separated for multi-country; full counting. |

**Venue tagging (script 13).** Two columns, both kept:
- `venue_group` — binary `ADHO-global` vs `regional` (headline contrast).
- `venue_series` — **B1 rule**: any ADHO-lineage series (1–4) → `ADHO-global`;
  else the most-specific regional series (fewest member conferences, ties by
  lowest id); no membership → `unaffiliated`. Keeps regional series separate.

**Matching (script 21).** Scored on the cited-work **title alone** (author/year
tail stripped before normalising — this is what moved thousands of refs from
fuzzy into the exact tier). Tiers: DOI → exact normalised-title → fuzzy
Jaro-Winkler. Thresholds: **≥0.95 auto-accept**, **0.85–0.95 review**
(written sorted best-first with the matched `oa_title`), **<0.85 discard**.
DOI/exact always accepted. Precision-first: a false match corrupts country
numbers, a miss only shrinks the sample.

---

## 5. Current results (snapshot ~June 2026)

**Conference reference matching (all-works index):**
- ~43.6k references in → **11,645 accepted (26.7%)** — DOI 2,096, exact-title
  8,356, fuzzy 1,193 (all ≥0.95). Review band (0.85–0.95): ~3,046.
- Cited-work country coverage: **~43%**. Resolved citation edges: ~5,020 across
  ~1,868 conference works.

**Endogeneity (any-overlap):**
- ADHO-global conference ~**42%**, roughly flat over time.
- Journals decline from ~42% (2007) to ~25% (recent) — the conference-vs-journal
  **divergence is the robust headline finding**.
- Venue split holds: ADHO-global 42.2% vs regional 40.3%.

**Per-series limit (important).** Although `venue_series` separates ~10 regional
series, only **ADHO-global** (~4,520 resolved citations) and **DHd** (~331) clear
any usable citation volume — every other regional series resolves to *zero*
edges. The per-series analysis is therefore effectively ADHO-global vs DHd
(≈42% vs ≈40%, nearly identical). Lowering the floor 100→50 does not change this;
it is a **data-coverage limit**, not a threshold choice.

---

## 6. Notable workflow decisions (and their consequences)

- **`07_temporal_by_country` widened to the full ≥100 set.** Previously script 03
  capped this table at `TOP_N_COUNTRIES` (15), so fig3's per-country panel and any
  mean over it covered only 15 countries. Script 03 now writes the **full ≥100
  set** (e.g. 63 countries in the core tier) to `07`, while a separate top-15
  subset still feeds the convergence slopes (`10`) and the mixed-effects model —
  so published convergence/divergence numbers are unchanged. fig3b draws the
  **top 15 countries** by volume as lines (for readability) but overlays a bold
  **equal-weight mean** computed over the **full ≥100 set** (simple average of
  per-country excess, every country weighted equally — deliberately *not*
  citation-weighted, and not limited to the 15 drawn, so the central-tendency
  line represents all analysable countries).
- **fig2 shows EXCESS, not raw share.** The country×country heatmap now colours
  each cell by **observed minus expected citation share** (diverging palette,
  white at 0; red = cites more than chance, blue = less). Expected share = the
  cited country's share of the **full** citation pool (the same null model as
  `expected_scr` in `05`). The diagonal is each country's self-country excess
  endogeneity; off-diagonal is bilateral over/under-citation. Colour limits are
  capped at the 98th percentile of |excess| so a few extremes don't wash out the
  rest. (The old version showed raw row-normalised share, where the diagonal
  trivially dominated.)
- **Offline matching replaced the API.** OpenAlex `title.search` times out on a
  large fraction of queries; resolving ~43k references that way is infeasible.
  Offline matching against the snapshot has no timeout. DOI lookups (free, fast)
  still use the API.
- **All-works index, not subfield-filtered.** A Lit+Linguistics-only index matched
  only ~5% of references (most conference citations point outside those
  subfields). The all-works index (~250M works) is queried with DuckDB so it runs
  on bounded RAM.

---

## 7. Reproducibility notes

- **renv** governs the package set. Run the canonical pipeline under renv on your
  own machine; any sandbox/ad-hoc R run is for verification only.
- **Record the snapshot date** — offline matches are valid "as of" that snapshot
  (OpenAlex refreshes quarterly). Everything after download is deterministic.
- Country names use the auditable Getty-TGN → ISO crosswalk (`data/tgn_to_iso.csv`).
- `data/` is gitignored **except `data/output/`**, which is tracked so results can
  be browsed without re-running.
- See `docs/offline_snapshot_pipeline.md` (snapshot + Habrok detail) and
  `docs/conference_linkage_notes.md` (CMU join logic) for specifics.

---

## 8. Known limitations (as they currently stand)

- **Reconstructed conference citation network.** Conference references are parsed
  from full text, so three coverage filters compound: a reference must be
  (a) parseable, (b) present in OpenAlex, (c) have author-country data. This skews
  toward English-language / recent / well-formatted work — which cuts against the
  project's multilingual / Global-South aims. Report this attrition.
- **Per-series analysis is effectively two series** (§5) — a coverage limit.
- **Journal corpus** misses books/chapters, conference proceedings, and DH work
  not using the exact phrase "digital humanities" in listed journals.
