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

**It is synthetic and labelled by us.** We wrote the sentences and the labels on November 1, 2026, after writing the lexicons, and did not change the lexicons afterwards. Nobody independent has labelled it. It deliberately over-samples hard cases, so its error rates are not the error rates of everyday speech.

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
- **The model labelled most hedges as content.** Of the 16 hedges the lexicon found correctly, the model called 10 content ("sort of", "kind of", "Maybe", "probably", "I THINK", "Je pense", "un peu", "Peut-être", "Disons", "Je crois"). Hedge recall fell from 0.889 to 0.333. The eleventh wrong label was the restart "What I mean is".
- **Live overall F1 (0.788) is below the lexicon alone (0.819).** Fillers and restarts improved; hedges lost more than they gained.
- **The scripted arm's 0.877 / 0.820 did not predict the hedge drop.** We wrote those replies knowing the gold labels, with deliberate format faults. They tested the checking code, not the model's judgement, and none of them reads a hedge as meaning.
- **Every label passed code's check.** All 51 labels named a proposed candidate once and copied its quote exactly, so no rejection kept a lexicon count. The span check cannot catch a wrong label that quotes correctly; on this run, those are the 11 removed habits.

This run does not change which categories go to the model. Sending only fillers and restarts would raise the F1 on this corpus, but that choice would be tuned on the same 70 transcripts it is scored on. It is an open product decision, not a measured result.
