# Geographic Citation Insularity in Digital Humanities — speaker notes

Short-paper slot, ~10 min + Q&A. 10 slides. Spoken text ≈ 1,400 words ≈ 10:30 at a
relaxed pace; cut the bracketed sentences if the chair is waving.

Figures referenced live in `output/` (main repo) and `docs/figures/`.

---

## 1 · Title (0:15)

**On slide:** title, author, affiliation, repo QR.

Good morning. This is a talk about a simple question with an awkward answer: when
Digital Humanities scholars write a reference list, how much of it is from their own country?

---

## 2 · The question (1:00)

**On slide:** one line — *"Do DH scholars cite their own country more than they
should, and is that changing?"* — with three names beneath: Fiormonte 2012, Galina
Russell 2014, Risam 2019.

DH describes itself as international by design. For over a decade critics have said
the practice doesn't match the description: Fiormonte on Anglophone and Western
European dominance, Galina Russell on the geographic and linguistic skew of output,
Risam on how digital knowledge production reproduces global inequality.

Most of that evidence is qualitative, or counts where conference submissions come
from. Only two studies have looked at DH bibliometrically at scale — Tang and
colleagues in 2017, Spinaci, Colavizza and Peroni in 2022 — and neither asked the
citation-level question. So that's what we did. Three questions: how much do DH
scholars cite their own country; how much of that is *more than you'd expect*
given how much each country publishes; and is it changing between 2007 and 2025.

---

## 3 · Insularity in one slide (1:30)

**On slide:** the definition in plain words; below it, a small worked example
(a DE–FR paper citing a US–DE paper → insular); footer with majority rule and the
permutation test.

One definition, then one correction.

The definition: a citation is *insular* when the citing paper and the cited paper
share at least one author country. That's the "any overlap" rule. A paper from
Germany and France citing a paper from the US and Germany counts, because Germany is
on both sides. [There's a stricter majority rule too — more than half the citing
countries must appear on the cited side — and everything I'll show holds under it,
just with lower numbers.]

The correction: raw self-citation is meaningless on its own. The US produces the
most DH work, so US authors cite US work partly because there's so much of it. So
for every country we compute an *expected* rate — its share of everything that gets
cited — and compare. Two numbers carry the talk from here: **excess**, observed
minus expected, in percentage points; and **ratio**, observed over expected, which
tells you how many times more insular a country is than chance. We test excess with
a thousand-round permutation: shuffle the country labels on the cited side, keep the
citation graph, see if the real value is extreme.

---

## 4 · Two corpora (1:30)

**On slide:** two columns. Left "Journals": Spinaci list (19 Exclusively-DH
journals) + "digital humanities" in title/abstract → OpenAlex → ~17,600 works →
58,655 citation pairs → 63 countries with ≥100 citations. Right "ADHO conference":
Index of DH Conferences (CMU) → references parsed from abstract text → matched
offline against an OpenAlex snapshot → 11,645 resolved (27%) → ~5,000 edges.

Two corpora, built the same way at the end but very differently at the start.

The journal corpus follows Spinaci et al.: every work since 2000 in the 19 journals
they classify as exclusively DH, plus anything anywhere that says "digital
humanities" in its title or abstract. About 17,600 works from OpenAlex. For each one
we take every author country, follow every reference, fetch the cited work's
countries. That leaves 58,655 citations with country on both ends, 63 countries
with at least a hundred each.

The conference corpus is the new part. The Index of DH Conferences at Carnegie
Mellon gives us the abstracts with affiliations, but no machine-readable references.
So we pulled reference strings out of the full text, parsed them with AnyStyle, and
matched them — offline, against a local OpenAlex snapshot, because the search API
kept timing out — by DOI, then exact title, then a very conservative fuzzy match.
We accept 27 percent of references. That's precision over recall: a wrong match
corrupts a country count; a miss just shrinks the sample. About five thousand
citation edges survive, and we keep only the ADHO annual conference and its
predecessors, so we're not mixing in venues that are national by construction.
[I'll come back to what that filtering does to the sample.]

Same measures, same null model, applied to both.

---

## 5 · Everyone is insular (1:30)

**On slide:** six-row table — US, GB, CN, FR, FI, AT — columns N, observed, expected,
excess, ratio. Below: "All 30 countries with ≥100 citations: p < 0.001."

First result. Every single country cites itself more than chance. Not most — all
thirty with enough data, all below p of 0.001. This is structural, not a US quirk.

But look at the two lenses. By *excess*, the leaders are France and the US, both
around 31–32 points above expectation. The US cites itself 60 percent of the time
against an expected 29. By *ratio*, it's a different list: Finland at 31 times
chance, Austria 28, Greece 23. The US is at 2.

Same phenomenon, different shape. Big producers have a lot of insularity in absolute
terms because there's a lot of domestic work to cite. Small countries have a
domestic pool of one or two percent of the field and still send a quarter or a third
of their citations into it. That's where insularity is most *amplified* — small,
cohesive national communities, national-language scholarship, a handful of dominant
groups.

---

## 6 · Who cites whom (1:00)

**On slide:** `fig2_citation_heatmap.png`. Circle the diagonal and the US column in
the build.

The same null model, applied to every pair. Each cell is observed minus expected
share; red is more than chance, blue is less.

Two things to see. The diagonal is red all the way down — that's slide 5 again.
And the US column is mostly *blue*. Most countries cite the United States *less*
than its share of the field would predict. They're not spending those citations on
some third country; they're spending them on themselves. You can also see the
regional blocks — East Asia top-left, the German-speaking countries and the
Netherlands bottom-right. Hold on to the blue US column; it matters in two slides.

---

## 7 · Journals vs. conference (2:00)

**On slide:** `fig9_conf_vs_journal_temporal.png`.

This is the slide I'd like you to remember.

The teal line is the journal corpus. Insularity falls from roughly 42 percent in
2007 to about 25 percent in the most recent years. Country by country, only the US
decline is statistically significant on its own — about one point a year — but the
direction is nearly universal. The journal literature is, slowly, internationalising.

The purple line is the ADHO conference. Same measure, same null model. It sits at
about 42 percent and stays there. It's noisier, because the yearly samples are
smaller, but there is no downward trend to find. The German-language DHd — the only
regional series with enough resolved citations to measure — is at 40 percent, right
beside it.

So the field's flagship international venue shows none of the opening-up the
journals show. One reading: a conference is a live, co-located event, and you write
the abstract for the people you'll see in the room. Another: what gets into the
proceedings and what gets into a journal are shaped by different review cultures.
We can't separate those with this data. What we can say is that "DH is becoming more
international" is true of one venue type and not the other.

---

## 8 · Is this DH, or just science? (1:30)

**On slide:** the 4-row comparison table with Wu, Huang, Lu, Saxena & Traag (arXiv
2604.01602, 2026): Method / Domestic preference / Orientation toward the US / Trend.

A natural objection: maybe all of this is just what citation looks like everywhere.
Fortunately there's a very recent benchmark. Wu, Traag and colleagues published in
April a study of 39 million OpenAlex publications, 95 countries, 2000 to 2022 —
all of science — fitting a Bayesian gravity model that estimates a country-pair
citation preference after controlling for distance and for how much each city
publishes. Different estimator, same data source, same country logic. Their
preference score is a model coefficient; our ratio is a descriptive quantity. They
agree in direction, not in units — so read this table as *does the sign match*,
not *does the number match*.

Row two: they find strong domestic citation preference in every country. So do we.
Universal insularity is a science-wide fact, not a DH pathology.

Row three is where DH breaks from the pattern. In their data most countries cite the
US *above* expectation — a shared orientation toward the American literature. In DH,
that's the blue column: most countries cite the US *below* expectation. [Whether
that's the humanities generally or DH specifically, we can't yet say; their four
domains are physical, social, life and health sciences, and the humanities aren't
broken out.]

Row four: they find the effect of distance on citation is tiny and shrinking, but
country bias itself does *not* fade over two decades. Our conference corpus looks
like that. Our journal corpus doesn't — it's shedding insularity faster than
science at large. So the interesting DH result isn't that it's insular; it's that
one half of it is stopping.

---

## 9 · Caveats and next steps (1:00)

**On slide:** two short lists. Caveats: reconstructed conference network (must be
parseable, in OpenAlex, and have country → skews English/recent); per-series is
effectively ADHO vs DHd; keyword self-identification; full counting; country ≠
language. Next: History / Literature / Sociology / Political Science benchmark;
re-run Wu et al.'s model on the DH corpus.

Caveats, quickly. The conference network is reconstructed from text, so three
filters compound: a reference has to be parseable, present in OpenAlex, and carry
country metadata. That tilts the conference sample toward English-language, recent,
well-formatted work — which cuts against exactly the multilingual and Global South
questions we care about. Treat the conference line as indicative. Only ADHO and DHd
clear the citation floor; every other regional series resolves to nothing. On the
journal side: the keyword search favours work that calls itself DH; full counting
inflates multi-country papers; and country is a rough proxy for language and
culture.

Next: we're benchmarking DH against History, Literature, Sociology and Political
Science with identical methods. And the cleanest way to settle whether the US-column
difference is field or method is to fit Wu et al.'s preference model on our corpus —
that's in progress.

---

## 10 · Take-home (0:30)

**On slide:** three lines and the repo QR.

Three things. Geographic self-citation in DH is universal and significant, and it's
most amplified in small national communities, not the large ones. DH journals have
been shedding it for twenty years. The ADHO conference hasn't. Code, data and the
conference-matching pipeline are in the repository. Thank you.

---

## Q&A backup slides (don't present; have ready)

- **B1 · Bridge scholars** — `fig5_bridge_scholars.png`. 668 authors with ≥3 works
  and ≥10 citations; entropy over cited countries; top scholars cite 40+ countries;
  share of top-quartile authors peaked ~2010 and fell as the field grew.
- **B2 · Sensitivity tiers** — `fig7_sensitivity.png`. Exclusively / Core / All:
  same ranking, same decline.
- **B3 · Per-country slopes** — `fig3_temporal_trends.png` lower panel. US −1.0
  pp/yr, p < .001, R² = .68; everyone else negative but n.s.
- **B4 · Conference matching funnel** — ~43.6k references → 11,645 accepted (DOI
  2,096 · exact title 8,356 · fuzzy ≥0.95 1,193) → ~43% of cited works carry country
  → 4,851 edges from 1,806 works (20.5% of the 8,823 conference works).
- **B5 · Majority-rule numbers** — journals 19% overall; conference 33.7%. Same
  divergence.

## Likely questions

- *"Isn't the flat conference line just small-sample noise?"* — Partly; yearly n is
  a few hundred. But the pooled ADHO rate (41.7%, n = 4,520) sits where journals were
  in 2007, and there's no year after 2015 below the journal line. Noise would
  scatter around the journal trend, not sit above it.
- *"Why any-overlap rather than majority?"* — Any-overlap is the generous
  definition; it makes the *decline* harder to find, not easier. Majority rule
  gives the same story at lower levels (B5).
- *"Does language explain Finland/Austria/Greece?"* — Probably a large part. We
  can't separate language from country in this data; that's the honest limit.
- *"How comparable is your ratio to Wu et al.'s preference score?"* — In sign, yes;
  in magnitude, no. Theirs is a model coefficient net of distance and city volume;
  ours is a raw share ratio. Fitting their model on our corpus is the next step.
