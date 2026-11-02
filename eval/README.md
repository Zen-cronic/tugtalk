# Measurement eval

How accurate are the habit counts that `measure()` (`src/capture.mjs`) puts on every captured session? This eval answers that for the text step only: transcript in, filler, hedge and restart counts out. It does not test speech recognition.

Recompute it:

```sh
npm run eval                       # prints the table and checks it against eval/results.json
npm run eval -- --live             # prints what a live adjudication run would cost; makes no call
npm run eval -- --live --approved  # runs it (paid; needs BASETEN_API_KEY)
```

or `GET /v1/eval` on a running server (public, read-only, no user data). A test (`test/eval.test.mjs`) regenerates the results and fails if they drift from the committed file or from the README's first line.

## Corpus

`corpus.json`: 70 short transcripts (34 English, 36 French), including 12 clean negative controls.

**It is synthetic and labelled by us.** We wrote the sentences and the labels on November 1, 2026, after writing the lexicons. One later change: on November 2, `lexicon-en-v2` started counting "ah" and "er" as the filler "uh", because Meta's transcription wrote a spoken "uh" as "ah" in our test clips. The corpus has neither spelling, so no number here changed (`results.json`, `lexicon_changes`). Nobody independent has labelled it. It deliberately over-samples hard cases, so its error rates are not the error rates of everyday speech.

Labels are inline: `[F:um]` filler, `[H:I think]` hedge, `[R:sorry, let me restart]` restart. A restart is one explicit self-correction event, however many words it spans. Unmarked text is gold-negative. Immediate repeats ("the the", "vous vous") are reported separately by `measure()` and are not scored here.

Tags group the cases:

| Tag | What it tests |
|---|---|
| `plain` | Ordinary disfluent speech with in-lexicon phrases |
| `overlap` | "What I mean is" (restart) contains "I mean" (filler) |
| `multi_phrase_event` | "Sorry, let me restart" is one event made of two lexicon phrases |
| `content_trap` | A lexicon phrase used as content: "what kind of report", "du coup de fil", "il en fait trois", "Ben arrive" |
| `out_of_lexicon` | Real habits we chose not to list: filler "like", "quoi", "genre", "I suppose", "no wait" |
| `asr_variant` | Spellings a transcriber may produce: "Umm", "Heu", "peut être" without the hyphen |
| `repeat`, `dash`, `case`, `apostrophe` | Grammatical repeats, dashes, capitals, curly apostrophes |
| `negative_control` | Fluent sentences with no habits; every count is a false positive |

## Scoring

Per item and category: `tp = min(predicted, gold)`, `fp` = extra predicted counts, `fn` = missed gold labels; micro-averaged. Items are short and usually carry one phenomenon, which limits offsetting errors inside one item.

## Baseline

`flat_list_baseline` uses the same lexicon phrases as one flat list and counts every occurrence with Unicode word boundaries. It has no phrase precedence and no rule that a span counts once in one category. It is the straightforward way to build a lexicon counter, and it is what `measure()` must beat to justify its extra logic.

## Results and what they mean

See `results.json` for every number and the full list of disagreements. In short:

- On `plain`, `mixed`, `dash`, `case`, `repeat` and `overlap` cases, `measure()` is exact.
- The only place it beats the baseline is overlap: the baseline also counts the "I mean" inside "what I mean is". So the gain is real but narrow.
- Both systems fail the same `content_trap` cases (every one is a false positive) and miss every `out_of_lexicon` and `asr_variant` habit. That is the cost of a fixed lexicon without context rules.
- "Sorry, let me restart" counts as two restarts in both systems.
- Clean controls: 0 false counts for both.

A fair reading: the counts are exact on the speech they were designed for, and wrong in predictable, listed ways outside it. A better lexicon needs context rules and a corpus labelled by someone other than us.

## Adjudicated arm: scripted adjudication outputs, not live model runs

On a capture, Muse Spark Open labels each ambiguous word-list hit as a habit or content, and code checks every label before it changes a count (`src/adjudicate.mjs`; the README section "How Meta's models measure" explains the design). The `adjudicated_scripted` system measures what that **checking code** does, without paid calls:

- Code proposes the candidates on each corpus item exactly as it does on a capture: 51 candidates on 42 items. The 15 pure vocal fillers ("um", "uh", "euh") are counted without asking.
- `scripted-adjudication.json` holds one scripted reply per item, as raw model text. We wrote them on November 2, 2026, knowing the gold labels. Replies without a fault give the gold answer. 14 of the 42 carry one deliberate fault each, named in the file: 3 wrong labels, 4 edited quotes, a capitalised label, a missing candidate, a conflicting duplicate, an empty reason, an invented candidate, a reply cut off mid-JSON (answered on the retry) and two prose answers with no JSON.
- The replies go through the same parser, shape check, one-retry rule and label check as live replies.

What it shows (`results.json`, `adjudication` and `systems.adjudicated_scripted`):

| System | Precision | Recall | fp | fn |
|---|---|---|---|---|
| Flat word list | 0.754 | 0.852 | 17 | 9 |
| Lexicon only (`measure()`) | 0.788 | 0.852 | 14 | 9 |
| Adjudicated, scripted replies | 0.877 | 0.820 | 7 | 11 |

- Code rejected 8 of the 51 labels (4 quote mismatches, 1 invalid label, 1 missing, 1 duplicate, 1 empty reason), had no usable reply for 1 more, and kept the lexicon count for all 9.
- 7 of the 12 content traps were removed. The other 5 stayed counted, because their label was rejected, never arrived as JSON, or was wrong.
- Recall fell from 0.852 to 0.820. Two wrong "content" labels removed real habits ("probably", and "Ben" read as a name). A wrong label that quotes the span correctly passes the check. That is the limit of a span check, and the eval counts these: 3 accepted wrong labels.
- The model can only remove proposed hits, so adjudication cannot raise recall. Out-of-lexicon habits ("like", "quoi") stay missed, and "Sorry, let me restart" still counts as two restarts.
- Clean controls stay at 0.

What it does not show: how often Muse Spark Open itself labels correctly. 28 of our 42 scripted replies give the gold answer because we wrote them that way. Only a live run can measure the model; the one we ran is below.

## Live arm: live, one run on 2026-11-02, self-labelled corpus

`npm run eval -- --live` prints the cost of a live run and stops: **42 Muse Spark Open calls** (one per item with candidates), at most 84 if every first reply needs the larger-budget retry. With `--approved` and `BASETEN_API_KEY` set, it runs the production adjudication client on every item and writes `eval/live-results.json`. `npm run eval` does not regenerate that file; a new live run overwrites it.

It ran once, on November 2, 2026 (`ran_at` 15:07 UTC), with `reasoning_effort: "low"`. All 42 calls returned HTTP 200 with `finish_reason` `stop` on the first attempt, so there were no retries. The median was 1.56 s per call, from that run's call log; `live-results.json` does not store timings. The corpus is the same self-labelled one as above (the file records its SHA-256).

| System | Precision | Recall | F1 |
|---|---|---|---|
| Lexicon only (`measure()`) | 0.788 | 0.852 | 0.819 |
| Adjudicated, scripted replies | 0.877 | 0.820 | 0.847 |
| **Adjudicated, live** | **0.953** | **0.672** | **0.788** |

By category, live against the lexicon:

| Category | Live precision | Live recall | Live F1 | Lexicon F1 |
|---|---|---|---|---|
| Fillers | 1.000 | 0.800 | 0.889 | 0.800 |
| Hedges | 1.000 | 0.333 | 0.500 | 0.865 |
| Restarts | 0.846 | 0.846 | 0.846 | 0.800 |

What it shows:

- **Precision rose and recall fell.** The model labelled all 12 content traps as content, and code removed every one of them. It also labelled 11 real habits as content, and code removed those too.
- **The model labelled most hedges as content.** Of the 16 hedges the lexicon found correctly, the model called 10 content ("sort of", "kind of", "Maybe", "probably", "I THINK" in the one-line answer "I THINK SO", "Je pense", "un peu", "Peut-être", "Disons", "Je crois"). Where "I think" opened a statement, as in "I think the budget is fine", it labelled it a habit, in 3 of 3 items, so there the word list and the model agree. Hedge recall fell from 0.889 to 0.333. The eleventh wrong label was the restart "What I mean is".
- **Live overall F1 (0.788) is below the lexicon alone (0.819).** Fillers and restarts improved; hedges lost more than they gained.
- **The scripted arm's 0.877 / 0.820 did not predict the hedge drop.** We wrote those replies knowing the gold labels, with deliberate format faults. They tested the checking code, not the model's judgement, and none of them reads a hedge as meaning.
- **Every label passed code's check.** All 51 labels named a proposed candidate once and copied its quote exactly, so no rejection kept a lexicon count. The span check cannot catch a wrong label that quotes correctly; on this run, those are the 11 removed habits.

This run does not change which categories go to the model. Sending only fillers and restarts would raise the F1 on this corpus, but that choice would be tuned on the same 70 transcripts it is scored on. It is an open product decision, not a measured result.

## Held-out check: model-only words and hedge adjudication

The word list leaves out filler "like" and French "genre" and "quoi", because each is a filler in some sentences and content in others ("I like the plan" against "it's, like, mostly done"). With `ADJUDICATE_MODEL_ONLY=1` (off by default), code proposes every occurrence of them to Muse Spark Open in the same adjudication call, and the record gets a separate `model_only` block. It is `counted` only when every one of those words got a label that passed code's check; otherwise it is `not_counted` and has no counts. These words never enter `metrics`, `lexicon_count` or `adjudicated_count`, so the measured numbers, the watch number and remeasurement are unchanged. With the flag off, the request and the stored record are byte-identical to before (`test/adjudicate.test.mjs` pins their hashes).

Whether the flag is ever turned on is decided by one live run on a set we did not write.

### The set

`heldout-v1.json`: **a synthetic held-out set: 60 transcripts written and labelled by a separate agent, not real speech.** That agent was given only the task and the five word families. It never saw the adjudication prompt, `corpus.json` or any past result. Its labelling rules are inside the file. 30 transcripts are English and 30 French.

| Family | Filler | Content |
|---|---:|---:|
| like | 24 | 23 |
| genre | 9 | 8 |
| quoi | 11 | 11 |

There are also 44 hedge-family spans: 31 hedge and 13 not hedge (a type, a quantity, "rather", "think about", "believe in", someone else's quoted words). 8 of the hedges and 2 of the non-hedges use phrases outside our word list ("I'm not sure", "Perhaps", "plutôt", "Je ne suis pas sûr", "Probablement"), so no system here can count them except the count-all baseline.

We spot-checked 10 labels chosen at random against the file's rules: 10 of 10 agree. We did not change any label.

### Scoring

```sh
npm run eval -- --heldout                    # stub replies (0 paid calls), plus the saved live run if there is one
npm run eval -- --heldout --live             # prints what a live run would cost; makes no call
npm run eval -- --heldout --live --approved  # the live run (paid; needs BASETEN_API_KEY)
```

Every labelled occurrence is scored once: counted or not. Precision, recall and F1 are micro-averaged.

- **Model-only class:** every "like", "genre" and "quoi"; a positive is one labelled filler. All 86 are pooled for the decision, and each word is also shown on its own.
  - *model-only*: counted when its transcript's `model_only.status` is `counted` and its label is `habit`. A `not_counted` transcript counts none of its words, because that is what a person would see.
  - *count-all*: every occurrence counted, which is what adding the words to the list would do. Precision 0.512, recall 1, F1 0.677.
  - *count-none*: nothing counted, which is what the lexicon and adjudication do today. F1 0.
- **Hedge class:** the 44 labelled hedge-family spans; a positive is one labelled hedge.
  - *lexicon*: counted when a word-list hedge hit has exactly that span. Precision 0.676, recall 0.742.
  - *adjudication*: counted when the lexicon counts it and a verified "content" label did not remove it.
  - *count-all* and *count-none*: every labelled span counted, or none. Count-all knows where the labelled spans are, so it is an upper reference, not a real system.
  - A word-list hedge hit outside any labelled span would count as a false count. There are none in v1.

`npm run eval -- --heldout` first runs a stub that labels every candidate "habit" through the real request, parser and label check. Adjudication then equals the lexicon and model-only equals count-all. It checks the pipeline and the scoring, not the model.

### Pre-registered rules

Committed before the live run, and not changed after it.

1. **The model-only class ships** (`ADJUDICATE_MODEL_ONLY=1` on the hosted app) only if, on the live run, its F1 on the 86 model-only occurrences beats both count-all (0.677) and count-none (0), **and** its precision is at least 0.8. A tie does not ship. Otherwise the flag stays off and the README keeps "like", "genre" and "quoi" as a known limit.
2. **Hedges leave adjudication** if adjudicated hedge recall on the live run is more than 0.2 below the lexicon's (that is, below 0.542). Then hedges are never adjudication candidates. This changes `adjudicated_count` going forward, never `metrics` or the watch number.
3. **Both results are reported** in the README whichever way they go, as "a synthetic held-out set: 60 transcripts written and labelled by a separate agent, not real speech".

How the run is done:

- **One run.** It uses the production adjudication client (`meta-models/muse-spark-open-1026`, `reasoning_effort: "low"`, temperature 0) with the model-only words on, so each transcript is one call, and both rules are read from that same run. There are 60 calls, or at most 120 if every first reply needs the larger-budget retry.
- A failed call is part of the result: that transcript keeps the lexicon count and its model-only words are not counted.
- **A completed run is final.** It is never repeated to improve a number, and the prompt, the label check and the scoring do not change between these rules and the run. Only a run that crashes before writing `heldout-live-results.json` may be started once more.
- If the run does not complete, the flag stays off and the README is unchanged.
- One caveat, stated in advance: hedges are scored with the model-only words in the same call. If rule 1 fails, the hosted app adjudicates without them, so its hedge labels come from a slightly different request than the one measured here.
