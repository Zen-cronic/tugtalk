# Measurement eval

How accurate are the habit counts that `measure()` (`src/capture.mjs`) puts on every captured session? This eval answers that for the text step only: transcript in, filler, hedge and restart counts out. It does not test speech recognition.

Recompute it:

```sh
npm run eval        # prints the table and checks it against eval/results.json
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
