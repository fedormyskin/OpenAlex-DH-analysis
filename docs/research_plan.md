# Research Plan: Citation Endogeneity in Digital Humanities

## 1. Context and Motivation

Building on Spinaci, Colavizza & Peroni (2022), who mapped DH research across bibliographic databases and created a curated journal list, this project investigates **geographic citation endogeneity** in DH — the extent to which DH scholars cite work from their own country or region versus engaging with global scholarship. The study will also identify scholars who act as "bridges" connecting geographically diverse research communities.

## 2. Corpus Construction Strategy

We use a **two-pronged approach** to define the DH corpus:

### 2.1 Source-based: DH Journal List (Spinaci et al.)

From the uploaded CSV (based on the Spinaci et al. list), we select journals classified as **Exclusively** (19 journals) and **Significantly** (17 journals). These are the same levels Spinaci et al. used for their analysis.

**Exclusively DH journals (19):**

| ID | Title | E-ISSN | P-ISSN |
|----|-------|--------|--------|
| 1 | Umanistica Digitale | 2532-8816 | — |
| 2 | Frontiers in Digital Humanities | 2297-2668 | — |
| 3 | Digital Scholarship in the Humanities (DSH) | 2055-768X | 2055-7671 |
| 4 | Digital Humanities Quarterly (DHQ) | 1938-4122 | — |
| 5 | Digital Studies / Le champ numérique | 1918-3666 | — |
| 6 | Journal of Digital Humanities | 2165-6673 | — |
| 7 | Journal of Cultural Analytics | 2371-4549 | — |
| 8 | Journal of Digital Archives and Digital Humanities | 2616-5732 | — |
| 9 | Digitális Bölcsészet / Digital Humanities | 2630-9696 | — |
| 10 | Revista de humanidades digitales | 2531-1786 | — |
| 11 | Journal of the Japanese Association for Digital Humanities | 2188-7276 | — |
| 12 | Journal of Data Mining and Digital Humanities | 2416-5999 | — |
| 13 | International Journal of Digital Humanities | 2524-7840 | 2524-7832 |
| 14 | Journal on Computing and Cultural Heritage (JOCCH) | 1556-4711 | 1556-4673 |
| 15 | Literary and Linguistics Computing | 1477-4615 | 0268-1145 |
| 16 | Journal of the Text Encoding Initiative | 2162-5603 | — |
| 17 | Computers and the Humanities | 1572-8412 | 0010-4817 |
| 18 | International Journal of Humanities and Arts Computing | 1755-1706 | 1753-8548 |
| 19 | Digital Medievalist | 1715-0736 | — |

**Significantly DH journals (17):**

| ID | Title | E-ISSN | P-ISSN |
|----|-------|--------|--------|
| 20 | Digital Library Perspectives | 2059-5824 | 2059-5816 |
| 21 | Journal of Library Metadata | 1937-5034 | 1938-6389 |
| 22 | Journal of Quantitative Linguistics | 1744-5035 | 0929-6174 |
| 23 | Language Resources and Evaluation | 1574-0218 | 1574-020X |
| 24 | Virtual Archaeology Review | 1989-9947 | — |
| 25 | D-Lib Magazine | 1082-9873 | — |
| 26 | Computational Linguistics | 1530-9312 | 0891-2017 |
| 27 | AI & SOCIETY | 1435-5655 | 0951-5666 |
| 28 | International Journal on Digital Libraries | 1432-1300 | 1432-5012 |
| 29 | ENTHYMEMA | 2037-2426 | — |
| 30 | Italiano LinguaDue | 2037-3597 | — |
| 31 | Lingue e culture dei media | 2532-1803 | — |
| 32 | JLIS | 2038-1026 | 2038-5366 |
| 33 | Doctor virtualis | 2035-7362 | — |
| 34 | International Journal of Digital Curation | 1746-8256 | — |
| 35 | The Journal of Interactive Technology and Pedagogy | 2166-6245 | — |
| 36 | Code4Lib Journal | 1940-5758 | — |

### 2.2 Keyword-based: Title/Abstract Search

Additionally, we search for any work (regardless of venue) that explicitly mentions **"digital humanities"** in title or abstract. As you noted, this self-identification signal means the authors position themselves within the DH community, making these works relevant even when published outside DH journals.

**OpenAlex query:**
```
/works?filter=title_and_abstract.search:"digital humanities",publication_year:>1999
```

### 2.3 Deduplication and Corpus Flags

Works found via both methods will be deduplicated by OpenAlex ID. Each work gets flags:
- `source_journal`: TRUE if found via journal list
- `source_keyword`: TRUE if found via keyword search
- `dh_level`: "Exclusively" / "Significantly" / "keyword_only"

This allows later sensitivity analyses (e.g., are endogeneity patterns different for core DH journals vs. keyword-identified works?).

### 2.4 Critical Note on Limitations

**What we're missing:**
- DH conference proceedings (especially the annual ADHO DH conference) — a major venue but often not well-indexed in OpenAlex
- Books and book chapters — important in humanities
- DH work that doesn't use the exact phrase "digital humanities" and isn't published in listed journals (e.g., a computational literary study in a literature journal)

This should be acknowledged as a limitation. The corpus is biased toward journal-based, self-identified DH work.

## 3. Data Retrieval Pipeline

### 3.1 Phase 1: Retrieve DH Works

**Step 1a — Journal-based retrieval:**
For each journal, find its OpenAlex Source ID via ISSN, then query:
```
/works?filter=primary_location.source.id:<SOURCE_ID>,publication_year:>1999
&select=id,title,publication_year,authorships,referenced_works,type
&per-page=200&cursor=*
```

**Step 1b — Keyword-based retrieval:**
```
/works?filter=title_and_abstract.search:"digital humanities",publication_year:>1999
&select=id,title,publication_year,authorships,referenced_works,type
&per-page=200&cursor=*
```

**Rate limit awareness:** 100k credits/day with API key. List queries = 10 credits/page (200 results). Budget:
- ~36 journals × ~500 works avg = ~18,000 works → ~90 pages → 900 credits
- Keyword search: unknown size, but likely 5,000–15,000 → ~75 pages → 750 credits
- Phase 1 total: ~1,650 credits (very manageable)

### 3.2 Phase 2: Retrieve Cited Works

For each DH work, extract the `referenced_works` list (OpenAlex IDs of outgoing citations). Batch-fetch these in groups of 50 using pipe-separated ID filters:

```
/works?filter=openalex_id:W123|W456|...|W999
&select=id,authorships,publication_year
&per-page=200
```

**Budget estimate:**
- Assume ~15,000 DH works × 25 references avg = 375,000 cited works
- After deduplication: likely ~150,000–200,000 unique cited works
- At 50 per batch: ~3,000–4,000 API calls → 30,000–40,000 credits
- Feasible within 1 day's budget

### 3.3 Data to Extract per Work

**For citing works (DH corpus):**
- `id` (OpenAlex ID)
- `publication_year`
- `authorships` → for each author: `countries[]`, `institutions[].country_code`
- `referenced_works` (list of cited OpenAlex IDs)

**For cited works:**
- `id`
- `publication_year`
- `authorships` → `countries[]`, `institutions[].country_code`

## 4. Country Assignment

### 4.1 Full Counting

Each work is assigned **all** countries from its authors' affiliations. The `authorships[].countries` field (available per author) is preferred because OpenAlex derives it from both matched institutions and raw affiliation parsing, providing better coverage than `institutions[].country_code` alone.

### 4.2 Tracking Multi-Country Works

Each work gets:
- `countries`: list of all unique country codes
- `n_countries`: count of distinct countries
- `is_multicountry`: boolean (n_countries > 1)
- `country_set`: sorted string of country codes for easy grouping (e.g., "DE-US")

## 5. Endogeneity Measures

For each citing work C (from country set S_C) that cites work R (from country set S_R):

### 5.1 Approach 1: Any Overlap

A citation is **endogenous** if `S_C ∩ S_R ≠ ∅` — any shared country between the citing and cited work.

This is the more generous definition. It will produce higher endogeneity rates because multi-country papers can "match" on any author's country.

### 5.2 Approach 2: Majority Rule

A citation is **endogenous** if the majority of countries in S_C are also present in S_R. Specifically:
- `|S_C ∩ S_R| / |S_C| > 0.5`

This is stricter: a paper by authors from DE, FR, US citing a paper from US alone would not count as endogenous (1/3 overlap), while a paper from DE alone citing a DE-US paper would (1/1 overlap).

### 5.3 Metrics to Compute

**Per country c, per year t:**

1. **Self-citation rate (any overlap):**
   `SCR_any(c,t) = (endogenous citations from c) / (total citations from c)`

2. **Self-citation rate (majority):**
   `SCR_maj(c,t) = (endogenous citations from c) / (total citations from c)`

3. **Citation diversity (Shannon entropy):**
   For each country c, compute entropy over the distribution of countries cited:
   `H(c,t) = -Σ_j p_j × log(p_j)`
   where p_j = proportion of citations from c going to country j. Higher entropy = more diverse.

4. **Herfindahl-Hirschman Index (HHI):**
   `HHI(c,t) = Σ_j p_j²`
   Lower HHI = more diverse. Complementary to entropy.

5. **Expected vs. observed endogeneity:**
   Under a null model where citations are random given the size of each country's DH output, what endogeneity rate would we expect? This controls for the fact that the US produces more DH works, so US authors citing US works is partly just base rate.

**Per region (continent/Global South):**
Same metrics aggregated to region level.

## 6. Identifying "Bridge" Scholars

### 6.1 Author-Level Citation Diversity

For each author a:
- Collect all works by a in the DH corpus
- Aggregate all their cited works' country sets
- Compute:
  - **Geographic reach**: number of distinct countries cited
  - **Citation entropy**: Shannon entropy over countries cited
  - **Self-citation rate**: share of citations going to own country
  - **Non-dominant share**: 1 - (share going to the single most-cited country)

### 6.2 Normalization

Raw entropy is confounded by productivity (more papers = more opportunities to cite diverse work). Normalize by:
- Comparing to the distribution expected given the author's country and publication year
- Using residuals from a regression of entropy on log(n_citations)

### 6.3 "Bridge Scholar" Criteria

An author qualifies as a bridge scholar if they are:
1. In the **top quartile** of citation entropy (after normalization)
2. Have **at least N publications** in the corpus (to be determined; maybe 5+)
3. Cite works from **at least K distinct countries** (maybe 10+)

We can also identify bridge scholars who specifically cite the **Global South** (using OpenAlex's `is_global_south` flag), which is arguably a stronger signal of global engagement.

## 7. Temporal Analysis

### 7.1 Time Windows

- Annual metrics for 2000–2025 (or latest available)
- 5-year rolling windows for smoother trends
- Break into periods: 2000–2005 (pre-boom), 2006–2012 (growth), 2013–2018 (maturation), 2019–present (recent)

### 7.2 Trends to Test

- Is overall endogeneity increasing or decreasing over time?
- Are some countries becoming less insular faster?
- Is the Global South becoming more integrated?
- Are the number and diversity of bridge scholars increasing?

### 7.3 Statistical Tests

- Mann-Kendall trend test for monotonic trends in endogeneity
- Mixed-effects models: endogeneity ~ year + (1|country), to account for country-level clustering
- Compare pre/post inflection points (if visible)

## 8. Implementation Plan

### 8.1 Technology Stack

- **R** (primary): `httr2` or `openalexR` for API access; `tidyverse` for data wrangling; `igraph` for network analysis; `ggplot2` + `sf` for visualization
- **Python** (if needed later): for any NLP on abstracts

### 8.2 R Package: openalexR

The `openalexR` package provides a convenient R interface. However, we should verify it supports:
- Cursor-based paging (for >10k results)
- The `select` parameter (to minimize data transfer)
- Batch ID lookups

If not, we can use `httr2` directly with the REST API.

### 8.3 Execution Steps

| Step | Task | Est. API Credits | Est. Time |
|------|------|-----------------|-----------|
| 0 | Set up API key, test queries | 100 | 1 hour |
| 1a | Find OpenAlex Source IDs for 36 journals | 360 | 1 hour |
| 1b | Retrieve all works from DH journals (2000+) | ~1,000 | 2 hours |
| 1c | Retrieve keyword-search works | ~750 | 1 hour |
| 1d | Deduplicate, create master corpus | 0 | 30 min |
| 2 | Extract all referenced_works IDs, deduplicate | 0 | 30 min |
| 3 | Batch-fetch cited works (country info) | ~40,000 | 4-6 hours |
| 4 | Build citation-country matrices | 0 | 2 hours |
| 5 | Compute endogeneity metrics | 0 | 2 hours |
| 6 | Author-level analysis (bridge scholars) | 0 | 2 hours |
| 7 | Temporal analysis and visualization | 0 | 3 hours |

**Total: ~42,000 credits (well within 1 day), ~1–2 working days of coding.**

## 9. Outputs and Deliverables

1. **Dataset** (for reproducibility): CSV/parquet files of the DH corpus with country assignments, citation links, and computed metrics
2. **Country × country citation matrix** (by year/period)
3. **Choropleth maps**: endogeneity rates by country
4. **Network visualization**: citation flows between countries
5. **Time-series plots**: endogeneity trends
6. **Bridge scholar rankings**: table and profiles
7. **Reproducible R scripts**: full pipeline from API queries to figures

## 10. Potential Issues and Mitigations

| Issue | Mitigation |
|-------|-----------|
| Many DH works lack institutional affiliation data → missing country | Report coverage rates; use `authorships.countries` (broader than institution-based); sensitivity analysis excluding works without country data |
| Small non-Anglophone DH journals may be poorly indexed in OpenAlex | Cross-check against Spinaci et al.'s coverage data; acknowledge as limitation |
| Some "Significantly" journals (e.g., Computational Linguistics) are not really DH — they inflate certain countries | Run separate analyses for Exclusively-only vs. full corpus |
| OpenAlex topic classification may not have a clean "Digital Humanities" topic | We're not relying on topics — our approach is journal-list + keyword, which is more defensible |
| Multi-country papers inflate endogeneity under "any overlap" | That's why we use both approaches; also report results for single-country papers separately |
| The keyword search for "digital humanities" may return irrelevant works (e.g., editorials about DH) | Filter by type (article, book-chapter) and manual spot-checks |
