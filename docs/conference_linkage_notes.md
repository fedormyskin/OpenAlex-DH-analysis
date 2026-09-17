# Linking the Index of DH Conferences to the OpenAlex corpus

This note documents how the **Index of DH Conferences** data extract
(`data/dh_conferences_data/`, Carnegie Mellon University) is connected to the
OpenAlex citation corpus built in scripts `01`–`12`. It is written so that
someone with only basic R / data-science skills can follow and reproduce it.

## 1. Why these two datasets do not share a key

The OpenAlex corpus identifies every work, author, and institution with an
**OpenAlex ID** (e.g. `W1549518189`, `A5015258192`) and uses **ISO alpha-2**
country codes (`US`, `GB`). The conference extract is a separate relational
database with its **own internal integer IDs**, **no OpenAlex IDs, no DOIs**,
and country names from the **Getty Thesaurus of Geographic Names** (e.g.
"Netherlands", not `NL`).

There is therefore **no deterministic join** between the two. We link them at
two levels, from safest to riskiest.

## 2. The conference data is relational — how the files join

A single person, their institution, and that institution's country live in
different files. Script `13` performs these joins:

```
works ──(conference)──> conferences ──(country)──> countries        (host country)
works <──(work)── authorships ──(appellation)──> appellations        (author name)
                      │
                      └─(authorship)─ authorship_affiliation ─(affiliation)─> affiliations
                                                                    │ (institution)
                                                                    └──> institutions ─(country)─> countries
```

Key fact (verified on the data): **92.0%** of the 21,592 authorships resolve to
a country this way, and **495 / 507** conferences have a host country. So the
country layer has strong coverage.

## 3. Layer 1 — country / institution (deterministic, recommended)

**Scripts:** `14_conference_country_linkage.R`
**Crosswalk:** `data/tgn_to_iso.csv` (Getty TGN country name → ISO alpha-2).

Both datasets are aggregated to ISO country codes and compared side by side
(`14_country_presence_compare.csv`). The unit is **presence / representation**
("who is *at* DH conferences vs. who *appears in* the OpenAlex corpus"), which is
exactly the gap flagged in `research_plan.md` §2.4 (DH conference proceedings,
especially ADHO, are a major venue missing from the journal/keyword corpus).

This layer has **no name-matching risk**. The only fuzzy step is the
country-name → ISO mapping, which is a small, fully auditable table:
196 of 197 country names map to ISO; the one blank ("Navajo Nation") has no ISO
code and is intentionally left empty (`needs_review = TRUE`). **Please verify
`data/tgn_to_iso.csv` once** — it was generated programmatically.

## 4. Layer 2 — conference citation endogeneity (extraction + matching)

To compute citation endogeneity on conference abstracts **side by side** with
the journal corpus, we recover the references that are missing from the
relational extract by parsing them out of `works.full_text`, then resolving each
reference to an OpenAlex work to obtain the cited work's author countries.

**Scripts:**
`15_extract_conference_references.R` → `15b_parse_references_anystyle.R` →
`16_resolve_references.R` → `17_conference_cited_countries.R` →
`18_conference_endogeneity.R`.

Format-specific extraction (`full_text` comes in two flavours):

* **XML / TEI:** three tiers, best first — `<biblStruct>` (fully structured),
  `<bibl>` (semi-structured), and any **DOI** string anywhere in the text
  (highest precision). These are already structured, so they skip AnyStyle.
* **TXT:** reference lists in the source PDFs are **heavily line-wrapped**, so a
  naive line-split produces fragments (~half the rows are broken). Script 15
  therefore also emits the raw reference **block** per work
  (`15_conf_txt_blocks.csv`), and **script 15b runs these blocks through
  [AnyStyle](https://anystyle.io)**, a purpose-built reference parser that
  reassembles wrapped references into structured fields (title, author, year,
  DOI). The de-wrapped output (`15b_parsed_references.csv`) is what feeds
  resolution; the noisy `txt_line` rows are kept only as a fallback.

**AnyStyle as a cached, reproducible step.** AnyStyle is a Ruby tool (external,
non-CRAN). To avoid forcing every re-runner to install Ruby, 15b runs it **once**
and commits its structured output CSV to the repo; script 16 reads that CSV.
Install once with `gem install anystyle-cli`. *Caveat:* AnyStyle's model is
English-trained, so non-English references (FR/ES/DE/JA in this corpus) parse
less reliably — 15b keeps a language guess so low-quality parses can be audited.

Each reference is then resolved **OpenAlex-first, Crossref-as-backup**: a DOI is
looked up directly; otherwise a title (+author/year) search is scored, with
**every low-confidence match flagged for manual review** rather than silently
accepted (see the review files in §7).

## 5. Reproducibility and open-science notes

* **The only networked step is reference resolution (`16`).** Every API response
  is cached to `data/cache/references/`; once the cache exists the pipeline runs
  offline and deterministically. Delete the cache to force a fresh pull.
* Resolved references are **valid as of the retrieval date** stamped by `16`,
  because OpenAlex / Crossref records change over time.
* API access uses your `OPENALEX_MAILTO` / `OPENALEX_API_KEY` from `.Renviron`
  (polite pool). Resolution is resumable — already-cached references are skipped.
* All scripts write to `data/output/`, consistent with the existing pipeline.

## 6. Limitations (please read before publishing)

1. **Citation edges are reconstructed, not native.** The relational extract has
   no work-to-work citation links; we recover them by parsing `full_text` and
   resolving each reference to OpenAlex. This is lossy at every step.
2. **Conference endogeneity rests on a biased subset.** Only works that (a) have
   full text (68.6%), (b) yield parseable references, **and** (c) whose cited
   works resolve to OpenAlex with country data enter the analysis. This skews
   toward English-language, recent, well-formatted abstracts — which cuts
   against the project's multilingual / Global-South visibility aims and **must
   be reported** alongside any side-by-side figure.
3. **Reference resolution is probabilistic.** Title-based matching produces
   errors; every low-confidence match is flagged for review (§7) rather than
   silently accepted. DOI-based matches are high precision.
4. **Different units.** OpenAlex journal corpus = published works; conferences =
   abstracts. Keep that in mind when interpreting any combined figure.

## 7. File inventory

| File | Produced by | Contents |
|------|-------------|----------|
| `data/tgn_to_iso.csv` | (generated, verify) | country name → ISO alpha-2 |
| `data/output/13_conf_authorships.csv` | `13` | author name + country per authorship |
| `data/output/13_conf_works.csv` | `13` | work + conference host country |
| `data/output/14_country_presence_compare.csv` | `14` | conference vs OpenAlex country shares |
| `data/output/14_institution_presence_conf.csv` | `14` | conference institutions by count |
| `data/output/15_conf_references.csv` | `15` | XML references + noisy txt_line fallback |
| `data/output/15_conf_txt_blocks.csv` | `15` | raw txt reference blocks (input to AnyStyle) |
| `data/output/15b_parsed_references.csv` | `15b` | AnyStyle-parsed txt references (cached) |
| `data/output/16_reference_matches.csv` | `16` | accepted reference → OpenAlex work ID |
| `data/output/16_reference_matches_review.csv` | `16` | **low-confidence matches, for your review** |
| `data/output/16_resolution_report.txt` | `16` | resolution rate + caveats |
| `data/output/17_conf_cited_countries.csv` | `17` | cited-work countries per conference work |
| `data/output/18_conf_country_endogeneity.csv` | `18` | conference endogeneity (side-by-side with `05`) |
