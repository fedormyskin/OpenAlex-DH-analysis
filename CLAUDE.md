# CLAUDE.md — Instructions for Claude Code

## Project Overview

This is an R-based research project analysing geographic citation endogeneity in Digital Humanities scholarship using OpenAlex bibliometric data.

## Repository

- Remote: https://github.com/fedormyskin/OpenAlex-DH-analysis.git
- Branch: main

## Project Structure

See the tree in README.md. Two pipelines, both producing the same endogeneity metrics:

- **Journal corpus (OpenAlex API):** `R/01 → 02 → 03`, figures in `R/06`.
- **Conference corpus (Index of DH Conferences + offline OpenAlex snapshot):** `R/13 → 15 → 15b (→ 15c)`, then on Habrok `19 → 20a → 21 → 17`, then `18`, figures in `R/06b`. SLURM jobs in `habrok/`.
- `eadh2026/` — the paper, speaker notes and slide deck. `docs/workflow.md` is the living record of the pipeline; update it when a script or parameter changes.

## Key Technical Details

- Language: R (≥ 4.1)
- Dependencies (renv.lock): `openalexR`, `tidyverse`, `httr2`, `jsonlite`, `lme4`, `countrycode`, `xml2`, `stringdist`, `stringi`, `cld3`, `arrow`, `duckdb`, `igraph`, `ggraph`, `tidygraph`, `viridis`, `patchwork`, `scales`; AnyStyle (Ruby) only for 15b
- API credentials go in `.Renviron` (never commit this file)
- Journal pipeline: 01 → 02 → 03 (sequential); 06 reads the `_core` outputs of 03
- Conference pipeline: 13 → 15 → 15b → [Habrok: 19 → 20a → 21 → 17] → 18 → 06b
- Phase 2 supports checkpointing (safe to interrupt/resume)
- `data/` is tracked selectively (see README "Data availability"): `02_dh_corpus_full.rds` and `04_cited_works.csv` are committed so 03 reproduces the paper exactly; the CMU extract (`data/dh_conferences_data/`) and the snapshot index are not
- Journal results are written to `data/`, conference results to `data/output/` — do not move them, the scripts hard-code these paths

## Sensitivity Analysis

Script 03 supports three corpus tiers controlled by `DH_CORPUS_FILTER` env var:
- `"exclusively"` → only Exclusively DH journals
- `"core"` → Exclusively + keyword-matched works
- `"all"` (default) → Core + Significantly DH journals

Output files get a suffix (`_exclusively`, `_core`, or none) for each tier.

## Conventions

- API key is read from environment variable `OPENALEX_API_KEY`
- Country codes use ISO 3166-1 alpha-2 (uppercase)
- Semicolons separate multiple countries in flat CSV fields
- Full counting for multi-country works
- Minimum 100 citations threshold for country-level analysis
- Temporal analysis window: 2007–2025
- Bridge scholar thresholds: 3+ works, 10+ citations

## openalexR Data Format

The `authorships` column from `openalexR` is a tibble with columns:
`id`, `display_name`, `orcid`, `author_position`, `is_corresponding`, `affiliations`, `affiliation_raw`

The `affiliations` column is a list of data frames with: `id`, `display_name`, `ror`, `country_code`, `type`, `lineage`

**Important:** Author IDs are in `$id` directly (NOT `$author$id` or `$au_id`).
