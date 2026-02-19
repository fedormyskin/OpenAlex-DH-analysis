# CLAUDE.md — Instructions for Claude Code

## Project Overview

This is an R-based research project analysing geographic citation endogeneity in Digital Humanities scholarship using OpenAlex bibliometric data.

## Repository

- Remote: https://github.com/fedormyskin/OpenAlex-DH-analysis.git
- Branch: main

## Project Structure

```
.
├── R/
│   ├── 01_build_dh_corpus.R       # Build DH corpus from OpenAlex API
│   ├── 02_fetch_cited_works.R      # Batch-fetch country data for cited works
│   └── 03_endogeneity_analysis.R   # Compute endogeneity metrics and bridge scholars
├── data/                           # Generated data (gitignored except .gitkeep)
├── output/                         # Figures and tables
├── docs/
│   ├── research_plan.md            # Full research plan
│   └── dh_journals.csv             # Journal list from Spinaci et al. 2022
├── .Renviron.example               # Template for API credentials
├── .gitignore
├── LICENSE                         # MIT
├── CLAUDE.md                       # This file
└── README.md
```

## Key Technical Details

- Language: R (≥ 4.1)
- Dependencies: `openalexR`, `tidyverse`, `httr2`
- API credentials go in `.Renviron` (never commit this file)
- Scripts run sequentially: 01 → 02 → 03
- Phase 2 supports checkpointing (safe to interrupt/resume)
- `data/` is gitignored — all outputs are reproducible from scripts

## Conventions

- API key is read from environment variable `OPENALEX_API_KEY`
- Country codes use ISO 3166-1 alpha-2 (uppercase)
- Semicolons separate multiple countries in flat CSV fields
- Full counting for multi-country works
