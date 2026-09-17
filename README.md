# Citation Endogeneity in Digital Humanities

An empirical study of geographic citation patterns in Digital Humanities (DH) scholarship using [OpenAlex](https://openalex.org/) bibliometric data.

## Research question

Are DH citation networks endogenous within countries? Which countries or regions are more insular, and which scholars act as "bridges" connecting geographically diverse research communities? How have these patterns changed over time? And does the flagship international venue — the ADHO annual conference — behave like the journal literature?

The current write-up is the EADH 2026 submission in [`eadh2026/`](eadh2026/) (paper, speaker notes, slides).

## Method

**Corpus construction** (two-pronged + sensitivity tiers):
1. All works published in 24 "Exclusively" DH journals — 19 from the [Spinaci, Colavizza & Peroni (2022)](https://doi.org/10.1093/llc/fqac016) curated list plus 5 additional journals
2. All works (any venue) mentioning "digital humanities" in title or abstract
3. 17 "Significantly" DH journals (Spinaci et al. 2022) for sensitivity analysis

Three corpus tiers for sensitivity testing:
- **Exclusively**: only works from Exclusively DH journals
- **Core**: Exclusively journals + keyword-matched works
- **All**: Core + Significantly DH journals

Includes articles, books, and book chapters from 2000 onward.

**Endogeneity measures:**
- *Any overlap*: a citation is endogenous if any author country is shared between citing and cited work
- *Majority rule*: endogenous if >50% of citing countries appear in the cited work's countries
- *Endogeneity ratio*: observed SCR / expected SCR (controls for country size in global scholarly output)

**Statistical testing:**
- Permutation test (1,000 iterations) for significance of country-level endogeneity
- Mixed-effects models (lme4) for convergence/divergence testing
- Per-country OLS slopes for temporal trends

**Additional metrics:** Shannon entropy, Herfindahl-Hirschman Index, bridge scholar identification.

**Second corpus — conferences:** the same measures and null model are applied to the [Index of DH Conferences](https://dh-abstracts.library.cmu.edu) (CMU), with the citation network reconstructed from abstract full text and resolved offline against an OpenAlex snapshot (see *Conference pipeline* below).

## Repository structure

```
.
├── R/                                   # numbered = run order within each pipeline
│   ├── 00_setup.R                       # one-time: renv + dependencies
│   ├── 01_build_dh_corpus.R             # journal 1: build DH corpus from OpenAlex (API)
│   ├── 02_fetch_cited_works.R           # journal 2: country data for cited works (API, checkpointed)
│   ├── 03_endogeneity_analysis.R        # journal 3: endogeneity, null model, permutation test, bridge scholars
│   ├── 06_visualizations.R              # journal figures fig1–fig7
│   ├── 13_load_conference_data.R        # conf 1: CMU relational extract → author/work countries + venue tags
│   ├── 15_extract_conference_references.R   # conf 2: reference strings from abstract full text
│   ├── 15b_parse_references_anystyle.R  # conf 3: parse txt references with AnyStyle (Ruby; output committed)
│   ├── 15c_add_language_columns.R       # conf 3b (optional): script/language columns on parsed refs
│   ├── 19_download_filter_snapshot.sh   # conf 4 (Habrok): stream + filter the OpenAlex works snapshot
│   ├── 20a_tsv_to_parquet.R             # conf 5 (Habrok): TSV index → Parquet
│   ├── 21_match_references_duckdb.R     # conf 6 (Habrok): DOI / exact / fuzzy match via DuckDB
│   ├── 17_conference_cited_countries.R  # conf 7 (Habrok): cited-work countries from the local index
│   ├── 18_conference_endogeneity.R      # conf 8: conference endogeneity, columns mirror 05_*
│   ├── 06b_conference_comparison.R      # conference-vs-journal figures fig8–fig10b
│   └── helpers/country_regions.R        # ISO alpha-2 → region mapping
├── habrok/                              # SLURM jobs for scripts 19 / 20a / 21 on the RUG Habrok cluster
├── data/
│   ├── 00_retrieval_date.txt, 00_session_info_phase1.txt, 01_source_ids.csv   # retrieval metadata
│   ├── 02_dh_corpus_full.rds            # retrieved DH corpus (tracked: input to 03)
│   ├── 04_cited_works.csv               # retrieved cited-work countries (tracked: input to 03)
│   ├── 05–12_*.csv                      # journal results; suffix _core / _exclusively = corpus tier
│   ├── tgn_to_iso.csv                   # Getty TGN → ISO crosswalk used by 13
│   ├── dh_conferences_data/             # CMU extract — NOT tracked, see Conference pipeline
│   └── output/                          # conference-pipeline results (13_*, 15*, 16_*, 17_*, 18_*)
├── output/                              # figures, 300 dpi PNG (fig1–fig10b)
├── eadh2026/                            # EADH 2026 paper (LaTeX), speaker notes, slide deck + builder
├── docs/
│   ├── research_plan.md                 # original design
│   ├── workflow.md                      # living record of the pipeline as built (start here)
│   ├── offline_snapshot_pipeline.md     # snapshot download + Habrok matching
│   ├── conference_linkage_notes.md      # CMU join logic
│   └── dh_journals.csv                  # journal list (Spinaci et al. 2022)
├── renv.lock                            # pinned package versions
├── .Renviron.example                    # template for API credentials
├── CLAUDE.md
├── LICENSE
└── README.md
```

## Setup

### Prerequisites

- R ≥ 4.1

### Install dependencies

We use [`renv`](https://rstudio.github.io/renv/) to pin package versions for reproducibility.

**First time setup:**
```r
source("R/00_setup.R")
```

This installs `renv` and all required packages (`openalexR`, `tidyverse`, `httr2`, `jsonlite`, `lme4`, `countrycode`, `xml2`, `stringdist`, `stringi`, `cld3`, `igraph`, `ggraph`, `tidygraph`, `viridis`, `patchwork`, `scales`), then creates a `renv.lock` file. (`xml2`, `stringdist`, `stringi`, and `cld3` support the conference-linkage pipeline, scripts 13–18; `cld3` adds language detection on reference titles in 15b.)

**Reproducing the environment (after cloning):**
```r
renv::restore()
```

### API key

1. Get a free OpenAlex API key at https://openalex.org/settings/api
2. Copy `.Renviron.example` to `.Renviron` and fill in your key and email:

```
OPENALEX_API_KEY=your_key_here
OPENALEX_EMAIL=your.email@example.com
```

3. Restart R so the environment variables are loaded.

### Running the pipeline

Run the scripts in order. Each script reads from and writes to `data/`.

```r
# Core pipeline
source("R/01_build_dh_corpus.R")      # ~5 min — builds DH corpus
source("R/02_fetch_cited_works.R")     # ~30-60 min — fetches cited works' countries
source("R/03_endogeneity_analysis.R")  # ~5 min — main analysis + permutation test

# Visualization
source("R/06_visualizations.R")        # ~1 min — fig1–fig7 (core tier)
```

`data/02_dh_corpus_full.rds` and `data/04_cited_works.csv` — the OpenAlex data as retrieved on 2026-02-19 — are tracked, so **you can start at script 03** and reproduce the reported numbers exactly. Re-running 01–02 refreshes the corpus against today's OpenAlex, which drifts daily.

**Sensitivity analysis** — run script 03 three times with different corpus filters:

```r
# Tier 1: Exclusively DH journals only
Sys.setenv(DH_CORPUS_FILTER = "exclusively")
source("R/03_endogeneity_analysis.R")

# Tier 2: Exclusively + keyword (core)
Sys.setenv(DH_CORPUS_FILTER = "core")
source("R/03_endogeneity_analysis.R")

# Tier 3: All (default — Exclusively + keyword + Significantly)
Sys.setenv(DH_CORPUS_FILTER = "all")
source("R/03_endogeneity_analysis.R")
```

Phase 2 supports checkpointing — if interrupted, re-running will resume from where it left off.

### Conference pipeline (Index of DH Conferences)

A second corpus — the [Index of DH Conferences](https://dh-abstracts.library.cmu.edu) (CMU) — is linked to the OpenAlex analysis so conference results can be reported **side by side** with the journal corpus.

**Getting the extract.** The CMU relational extract (~70 MB, `works.csv` alone 68 MB) is not redistributed in this repository. Download the "Data extract" from https://dh-abstracts.library.cmu.edu and unzip the CSVs into `data/dh_conferences_data/`. The analysis used the extract dated **2026-06-30** (`data/output/13_conf_load_report.txt` records what was loaded). Everything downstream of script 13 that does not need the OpenAlex snapshot can then be re-run locally; the snapshot-dependent outputs (`16_reference_matches.csv`, `17_*`) are committed so scripts 18 and 06b run without Habrok.

The conference references are resolved **offline against a local copy of the
OpenAlex works snapshot**, because the OpenAlex `title.search` API endpoint timed
out on a large fraction of queries and could not sustain the volume. The offline
matcher uses DuckDB over a Parquet index and has no timeout. See
`docs/offline_snapshot_pipeline.md` for the full offline design (run on the RUG
Habrok cluster; SLURM scripts in `habrok/`).

```r
# 1. Load + label the conference corpus (offline, no API)
source("R/13_load_conference_data.R")        # joins → author/work countries +
                                             # venue_group (ADHO-global vs regional)

# 2. Extract references from abstract full text
source("R/15_extract_conference_references.R") # XML refs + raw txt reference blocks
#   Then parse the txt blocks with AnyStyle (one-reference-per-line pre-segmentation
#   is applied first to fix line-wrapping):
#   Rscript R/15b_parse_references_anystyle.R
#   Rscript R/15c_add_language_columns.R       # optional: ref_script + cld3 language

# 3. Resolve references OFFLINE against the OpenAlex snapshot (see Habrok docs):
#   R/19_download_filter_snapshot.sh           # stream+filter snapshot -> works_index.tsv
#   R/20a_tsv_to_parquet.R                      # -> works_index_parquet/ (chunked, resumable)
#   R/21_match_references_duckdb.R              # DOI + exact + fuzzy match (>=0.95 accept)

# 4. Cited-work countries + endogeneity (offline)
source("R/17_conference_cited_countries.R")    # countries from the LOCAL parquet (no API)
source("R/18_conference_endogeneity.R")        # endogeneity, columns matching 05

# 5. Conference-vs-journal figures
source("R/06b_conference_comparison.R")        # fig8 (by country) + fig9 (over time)
```

**Venue split (avoids a confounder).** The Index mixes the global ADHO annual
conference (and the predecessor series that merged into it) with many regional /
national conferences (e.g. DHd, EHD) that are geographically concentrated *by
design*. To avoid that confound, script 13 tags each work two ways:

- `venue_group` — binary: `ADHO-global` vs `regional`. Drives the headline
  ADHO-vs-rest comparison. Script 18 runs per group via the `VENUE_GROUP` env var
  (output files get a `_adho` / `_regional` suffix).
- `venue_series` — finer: each regional series kept *separate* (DHd, JADH,
  DH Benelux, …) rather than pooled, because regional conferences are not
  interchangeable. Assigned by the **B1 rule**: a conference in any ADHO-lineage
  series (1–4) → `ADHO-global`; otherwise its most-specific regional series
  (fewest member conferences, ties by lowest id); no series membership →
  `unaffiliated`.

```r
Sys.setenv(VENUE_GROUP = "ADHO-global"); source("R/18_conference_endogeneity.R")
Sys.setenv(VENUE_GROUP = "regional");    source("R/18_conference_endogeneity.R")
Sys.setenv(VENUE_GROUP = "all");         source("R/18_conference_endogeneity.R")  # also writes per-series tables
```

The headline result holds in the **ADHO-global** subset alone (the genuinely
international venue), so it is not an artifact of regional conferences. `06b`
plots the `_adho` subset by default (override with `CONF_SUFFIX`).

**Per-series coverage limit (important).** Although `venue_series` separates ~10
regional series, only **two** survive the citation-resolution funnel with usable
edges: **ADHO-global** (~4,520 resolved citations) and **DHd** (~331). Every
other regional series resolves to *zero* citation edges — their works mostly lack
full text / parseable references / cited works with country data — so the
per-series analysis is effectively **ADHO-global vs DHd** (≈42% vs ≈40%
any-overlap endogeneity, nearly identical). Lowering the series floor from 100 to
50 citations (`SERIES_MIN_CITATIONS` in script 18) does not change this; it is a
data-coverage limit, not a threshold choice, and should be stated as such.

**AnyStyle prerequisite (script 15b).** Txt reference lists are heavily
line-wrapped, so script 15b pre-segments each block to one-reference-per-line,
then parses with [AnyStyle](https://anystyle.io) (`gem install anystyle-cli`).
The result `data/output/15b_parsed_references.csv` is committed, so collaborators
who have it can re-run matching without Ruby. XML/TEI references bypass AnyStyle.

Notes and caveats:

- **The conference dataset has no native citation edges.** References are
  recovered by parsing `works.full_text`, so the citation network is
  *reconstructed*. This means three coverage filters compound: a reference must
  be (a) parseable, (b) present in OpenAlex, and (c) have author-country data
  (~43% of resolved cited works do). Report this attrition transparently.
- **Matching scores on the title alone.** References are scored on the cited
  work's *title* (parsed out of the full citation string), not title+author+year:
  the trailing author/year text otherwise depressed the similarity of genuine
  matches. This change moved thousands of references from fuzzy into the *exact*
  tier and raised accepted matches to **11,645 (26.7%** of ~43.6k references;
  2,096 via DOI, 8,356 exact-title, 1,193 fuzzy).
- **Precision-first matching.** Manual inspection showed fuzzy matches below 0.95
  against a complete index are mostly coincidental word-overlap. The matcher
  therefore auto-accepts only DOI, exact-title, and fuzzy ≥ 0.95; the 0.85–0.95
  band goes to a review file (sorted best-first, with the matched OpenAlex title
  alongside the reference); below 0.85 is discarded. False matches would corrupt
  the country-level numbers, so recall is traded for precision.
- **Reproducibility:** after the snapshot download, everything is offline and
  deterministic. The snapshot date should be recorded (records change over time).
  Country names use an auditable Getty-TGN → ISO crosswalk (`data/tgn_to_iso.csv`).
- See `docs/conference_linkage_notes.md` (join logic) and
  `docs/offline_snapshot_pipeline.md` (offline matching, Habrok) for full detail.

## Figures

Script 06 generates the journal figures in `output/`:

| Figure | Description |
|--------|-------------|
| `fig1_citation_network.png` | Citation flow network (top 25 countries) |
| `fig2_citation_heatmap.png` | Citation heatmap grouped by region (top 30 countries) |
| `fig3_temporal_trends.png` | Excess endogeneity trends over time |
| `fig4_excess_endogeneity.png` | Excess endogeneity bar chart with significance |
| `fig5_bridge_scholars.png` | Bridge scholars: entropy vs self-citation |
| `fig7_sensitivity.png` | Sensitivity comparison across journal tiers |

Script `06b_conference_comparison.R` adds conference-vs-journal figures:

| Figure | Description |
|--------|-------------|
| `fig8_conf_vs_journal_excess.png` | Excess endogeneity by country, ADHO conference vs journals |
| `fig9_conf_vs_journal_temporal.png` | Endogeneity over time: each conference series (≥50 citations) vs the journal baseline |
| `fig9b_conf_vs_journal_temporal_by_country.png` | Endogeneity over time by country, conference vs journals |
| `fig10_endogeneity_by_series.png` | Endogeneity by conference series (≥50 citations) — in practice ADHO-global vs DHd |
| `fig10b_endogeneity_by_series_temporal.png` | Endogeneity over time, faceted by conference series |

## Data availability

`data/` is tracked selectively: everything needed to re-run the analysis from script 03 onward, plus every result table the paper and figures draw on. Large regenerable intermediates (`02_dh_corpus.csv`, `03_referenced_work_ids.txt`, `*.rds` other than the corpus, the CMU extract, the OpenAlex snapshot index) are gitignored.

| Path | Description |
|------|-------------|
| `data/00_retrieval_date.txt` | OpenAlex retrieval timestamp (2026-02-19) |
| `data/02_dh_corpus_full.rds` | DH corpus as retrieved, with authorships and reference lists — input to 03 |
| `data/04_cited_works.csv` | Country metadata for every cited work — input to 03 |
| `data/05_country_endogeneity*.csv` | Country-level endogeneity, null model, permutation p-values (`_core` is the paper's primary tier) |
| `data/06_temporal_overall*.csv`, `07_temporal_by_country*.csv` | Endogeneity by year, overall and per country |
| `data/08_bridge_scholars*.csv`, `12_bridge_temporal*.csv` | Bridge-scholar table and its share over time |
| `data/09_citation_flow_matrix*.csv` | Country × country citation counts |
| `data/10_temporal_slopes*.csv` | Per-country OLS slopes (convergence test) |
| `data/output/13_conf_*.csv` | Conference works and authorships with countries and venue tags |
| `data/output/15b_parsed_references.csv` | AnyStyle-parsed conference references (committed so re-runs skip Ruby) |
| `data/output/16_reference_matches*.csv` | Accepted (and review-band) reference → OpenAlex matches from the offline matcher |
| `data/output/17_conf_*.csv` | Conference citation edges with cited-work countries |
| `data/output/18_conf_*` | Conference endogeneity (all / `_adho` / `_regional`, per series) |
| `data/output/*_report.txt` | Run reports with counts, coverage and bias warnings |

OpenAlex data is [CC0 licensed](https://creativecommons.org/publicdomain/zero/1.0/). The Index of DH Conferences is © Carnegie Mellon University Libraries; see its site for terms.

## Paper and talk

[`eadh2026/`](eadh2026/) holds the EADH 2026 submission: `eadh2026.tex` (+ `.bib`, `.sty`, `img/`, `figures/` — compile with `pdflatex` → `biber` → `pdflatex` ×2).

## References

- Spinaci, G., Colavizza, G., & Peroni, S. (2022). A map of Digital Humanities research across bibliographic data sources. *Digital Scholarship in the Humanities*, 37(4), 1254–1268. https://doi.org/10.1093/llc/fqac016
- Priem, J., Piwowar, H., & Orr, R. (2022). OpenAlex: A fully-open index of scholarly works, authors, venues, institutions, and concepts.
- Aria, M., Le, T., Cuccurullo, C., Belfiore, A., & Choe, J. (2024). openalexR: An R-Tool for Collecting Bibliometric Data from OpenAlex. *The R Journal*, 15(4), 167–180.
- Weingart, S. B., Eichmann-Kalwara, N., Lincoln, M., et al. (2020–). *The Index of Digital Humanities Conferences*. Carnegie Mellon University. https://dh-abstracts.library.cmu.edu

## AI disclaimer
The whole workflow and code has been created with the assistance of Claude Code. The full pipeline is auditable and reproducible, independently of any LLM use.

## License

MIT
