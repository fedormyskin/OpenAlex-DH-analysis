# Citation Endogeneity in Digital Humanities

An empirical study of geographic citation patterns in Digital Humanities (DH) scholarship using [OpenAlex](https://openalex.org/) bibliometric data.

## Research question

Are DH citation networks endogenous within countries? Which countries or regions are more insular, and which scholars act as "bridges" connecting geographically diverse research communities? How have these patterns changed over time (2000–present)?

## Method

**Corpus construction** (two-pronged):
1. All works published in 19 "Exclusively" DH journals from the [Spinaci, Colavizza & Peroni (2022)](https://doi.org/10.1093/llc/fqac016) curated list
2. All works (any venue) mentioning "digital humanities" in title or abstract

Includes articles, books, and book chapters from 2000 onward.

**Endogeneity measures:**
- *Any overlap*: a citation is endogenous if any author country is shared between citing and cited work
- *Majority rule*: endogenous if >50% of citing countries appear in the cited work's countries

**Additional metrics:** Shannon entropy, Herfindahl-Hirschman Index, expected vs. observed endogeneity (null model), bridge scholar identification.

## Repository structure

```
.
├── R/
│   ├── 00_setup.R                  # One-time setup: installs renv + dependencies
│   ├── 01_build_dh_corpus.R        # Phase 1: Build DH corpus from OpenAlex
│   ├── 02_fetch_cited_works.R      # Phase 2: Retrieve country data for cited works
│   └── 03_endogeneity_analysis.R   # Phase 3: Endogeneity, bridge scholars, trends
├── data/                           # Generated data (gitignored, see below)
├── output/                         # Figures and summary tables
├── docs/
│   ├── research_plan.md            # Detailed research plan
│   └── dh_journals.csv             # DH journal list (Spinaci et al. 2022)
├── .Renviron.example               # Template for API key configuration
├── .gitignore
├── CLAUDE.md                       # Instructions for Claude Code
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

This installs `renv`, all required packages (`openalexR`, `tidyverse`, `httr2`, `jsonlite`), and creates a `renv.lock` file.

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
source("R/01_build_dh_corpus.R")      # ~5 min
source("R/02_fetch_cited_works.R")     # ~30-60 min (depends on corpus size)
source("R/03_endogeneity_analysis.R")  # ~2 min
```

Phase 1 logs the retrieval date and R session info to `data/`, so you can document exactly when the OpenAlex data was queried (the database updates daily).

Phase 2 supports checkpointing — if interrupted, re-running will resume from where it left off.

## Data availability

The `data/` directory is gitignored because intermediate files are large and fully reproducible from the scripts. Final output tables are saved in `output/`.

OpenAlex data is [CC0 licensed](https://creativecommons.org/publicdomain/zero/1.0/).

## References

- Spinaci, G., Colavizza, G., & Peroni, S. (2022). A map of Digital Humanities research across bibliographic data sources. *Digital Scholarship in the Humanities*, 37(4), 1254–1268. https://doi.org/10.1093/llc/fqac016
- Priem, J., Piwowar, H., & Orr, R. (2022). OpenAlex: A fully-open index of scholarly works, authors, venues, institutions, and concepts.
- Aria, M., Le, T., Cuccurullo, C., Belfiore, A., & Choe, J. (2024). openalexR: An R-Tool for Collecting Bibliometric Data from OpenAlex. *The R Journal*, 15(4), 167–180.

## License

MIT
