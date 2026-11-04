# Semantic assessment eval

How often does TugTalk's semantic objective assessment agree with a careful reader? In a confirmed practice round, Muse Spark Open (`meta-models/muse-spark-open-1026` on Baseten) labels each of the user's 1–3 objectives `addressed`, `partial`, `not_addressed` or `unclear` and quotes the answer as evidence. Code then checks every quote against the answer (`validateAssessment`, `src/practice.mjs`): a label of `addressed` or `partial` whose quotes do not match the answer exactly, at the stated offsets, becomes `unclear`. The round closes as addressed only when every objective ends up `addressed`.

This eval measures that whole step on text: answer and objectives in, the stored labels out.

## Pre-registration

Written and committed on 2026-11-04 before any model call on this set. The commit that adds this section, `eval/semantic-heldout-v1.json` and `scripts/eval-semantic.mjs` is the timestamp. After the run, only the Results section is filled in.

### Set

`eval/semantic-heldout-v1.json`: 40 spoken-style answers (plain transcript text, so no speech recognition), each with 1–3 objectives: 8 items with one objective, 16 with two, 16 with three, 88 objectives in all. Gold labels: 37 `addressed` (42%), 25 `partial` (28%), 26 `not_addressed` (30%). 7 items have every objective `addressed`; 33 do not.

Scenarios: a 1:1 asking to lead a launch or for a raise, standups, explaining a delay to a manager, client or steering group, interview answers, peer feedback, asking for help, pushing back on scope, an apology, a thank-you. Hard cases are tagged: objectives mentioned but not met ("we still need an owner"), paraphrases that do meet them ("I'm going to pass this time"), negation ("I'm not asking you to remove it"), an unrelated date ("since 2023" for a start date), vague answers ("sometime next week"), evasive and off-topic answers, fillers and restarts.

We wrote every answer and every label, before any call, from the definitions in the file. Nobody independent labelled it. Items were not tried on the model before they were frozen.

Label definitions (also in the file): `addressed` gives what the objective asks for (as in the product prompt, responding is enough; truth and outcome are not assessed, and a relevant refusal counts); `partial` gives some but not all of the required content, or a less specific version that still narrows it; `not_addressed` gives none of it. `unclear` is never a gold label.

### What is called

`scripts/eval-semantic.mjs` calls `replyToAnswer` (`src/voice.mjs`), the function a practice-round answer goes through on the hosted service, with the round as `createPracticeRecord` stores it before a first answer. That is the production system prompt (`semanticSystem`), user message (`semanticMessage`), model, reasoning effort (low), 8 s timeout per attempt, one retry after an unusable reply, and `validateAssessment`. Each item gets a fresh 120 s request budget; in production, transcription has already used some of it.

### Metrics

Primary: the **final** label, after the code check, which is what the product stores and shows.

1. **Exact-label accuracy per objective**: final label equals gold, over all 88 objectives. `unclear` and a failed call count as wrong.
2. **Confusion matrix**: gold (`addressed`, `partial`, `not_addressed`) by final label (the same three, plus `unclear` reported as a fourth column).
3. **False-addressed rate**: objectives whose gold is `partial` or `not_addressed` that end up `addressed`, over the 51 such objectives. This is the costliest error: it tells the user a point is covered when it is not. Also reported at the round level: of the 33 items that are not fully addressed, how many would close as addressed.
4. **Quote-check pass rate**: of the objectives the model labels `addressed` or `partial`, the share whose evidence code accepts (label kept rather than turned `unclear`). Also the share of returned quote spans that match the answer exactly.
5. **Run-to-run agreement**: the share of objectives with the same final label in run 1 and run 2, and the share of items with every label the same.

Secondary: the same numbers on the **raw** model label, before the code check, to show what the check changes.

### Run plan

One call per item = 40 calls, then a repeat run of all 40 for stability = 80 planned requests. Every HTTP request to Baseten is counted, retries included. Hard cap: 120 requests. An item starts only if two requests (its worst case) still fit under the cap; if one would not, the run stops there and the remaining items are reported as not run. Run 1 is the headline; run 2 is reported beside it, never instead of it. Each record keeps the Baseten request id.

### Decision rule

Report the numbers as measured. No pass/fail threshold, and no claim beyond the numbers. No re-run to improve them, no change to items, labels, prompt or scoring after the first paid call. A failed call is reported as a failed call, not retried by hand.

## Results

Run on 2026-11-04, 12:12–12:18 EST (17:12–17:18 UTC), `meta-models/muse-spark-open-1026` on Baseten, through `replyToAnswer`. All 80 planned items ran. Requests sent: 88 in this run (8 were the production retry after an unusable reply), plus 3 in an aborted start (see Deviations): **91 of the 120 cap**. Estimated cost: under $0.50 at Baseten's list price ($1.25 per million input tokens, $4.25 per million output), assuming about 450 input and at most 1,000 output tokens per request; the bill itself was not checked. Every record, with its Baseten request id (2 failed requests have none), is in `eval/semantic-results.json`; `node scripts/eval-semantic.mjs --score` recomputes the summary from them.

### Headline (run 1, final label after the code check)

| | Run 1 | Run 2 (repeat) |
|---|---|---|
| Exact-label accuracy, 88 objectives | **58 / 88 = 65.9%** | 60 / 88 = 68.2% |
| False addressed (gold partial or not addressed, labelled addressed) | **5 / 51 = 9.8%** | 2 / 51 = 3.9% |
| … of which gold not addressed | 0 / 26 | 0 / 26 |
| Rounds that would close as addressed but are not fully addressed | 2 / 33 | 1 / 33 |
| Fully addressed rounds that close | 6 / 7 | 5 / 7 |
| Objectives left `unclear` | 18 | 16 |
| Items with the whole assessment unavailable | 5 / 40 | 4 / 40 |

Accuracy by gold class, run 1: addressed 29 / 37 (78%), partial 7 / 25 (28%), not addressed 22 / 26 (85%). Run 2: 25 / 37, 9 / 25, 26 / 26.

Confusion matrix, run 1 (rows gold, columns final label):

| gold \ final | addressed | partial | not_addressed | unclear |
|---|---|---|---|---|
| addressed (37) | 29 | 0 | 0 | 8 |
| partial (25) | 5 | 7 | 7 | 6 |
| not_addressed (26) | 0 | 0 | 22 | 4 |

Run 2:

| gold \ final | addressed | partial | not_addressed | unclear |
|---|---|---|---|---|
| addressed (37) | 25 | 0 | 0 | 12 |
| partial (25) | 2 | 9 | 10 | 4 |
| not_addressed (26) | 0 | 0 | 26 | 0 |

### Raw model label, before the code check

Run 1: 71 / 88 = 80.7% exact, false addressed 6 / 51 = 11.8%. Run 2: 71 / 88 = 80.7%, false addressed 4 / 51 = 7.8%. The model's own labels are more accurate than the stored ones; most of the gap is labels the code check turned `unclear`. The check removed 1 false addressed in run 1 and 2 in run 2, by turning them `unclear`.

### Quote check

Of the objectives the model labelled `addressed` or `partial`, code kept the label for 41 / 52 = 78.8% in run 1 and 36 / 49 = 73.5% in run 2. In run 1 the 11 others were: 6 in replies code rejected as a whole (the item becomes unavailable), 2 whose quote did not match the answer at the given offsets, and 3 where the quotes matched but another field failed the check. Run 2: 9, 2 and 2. Of the quote spans returned, 54 / 58 (93.1%) and 54 / 56 (96.4%) matched the answer exactly. The records keep the labels and quote counts but not the whole raw reply, so which rule rejected a reply or a field (`validateAssessment` also requires `next_question`, a string `missing`, at most 3 spans and no unknown ids) was not recorded.

### Stability

Same final label in both runs: 63 / 88 objectives = 71.6%; every label the same on 26 / 40 items. Raw labels: 79 / 88 = 89.8%, 35 / 40 items. Most disagreement comes from a reply being rejected or a label turned `unclear` in one run and not the other.

### What the errors are

- Partial answers are the weak class: 7 (run 1) and 10 (run 2) of the 25 were labelled not addressed, for example "some time this week" for how much time is needed, and "a credit for those" for the credit amount. Our `partial` definition is stricter about what counts as some content than the model is.
- The false addressed were all gold partial: "a bunch of things, mostly some search stuff" for what got done (both runs), "we ended up going with one of the plans" for how it turned out, "I've done some front-end work before" for connecting experience, "I'm a perfectionist" for a weakness with an example, "some cleanup" for today's work, and in run 2 "trying to get better at saying no" for what you are doing to improve.
- No objective we labelled not addressed was ever labelled addressed, in either run, including the negation ("I'm not asking you to remove it"), the owner ("we still need an owner") and the unrelated date ("since 2023").
- One request in each run failed outright (a timeout at 8 s; a reply of the wrong shape after the retry).

### Deviations from the plan

- **Aborted start.** The first start was stopped by hand after 3 items, because two items in a row came back unavailable after one request each and that looked like a setup error. It was not: those were the production 8 s timeout. The script then saved records only at the end, so nothing was kept but its console log (s01 and s02 unavailable, s03 all addressed). The run was restarted from item 1, with those 3 requests counted against the cap (`--already-sent 3`); the script now also saves after every item. No call, prompt, item, label or scoring rule changed. If run 1 kept the aborted start's outcomes for s01–s03, its accuracy would be 54 / 88 = 61.4% and false addressed would stay 5 / 51.

### Limits

- 40 items and 88 objectives that we wrote and labelled ourselves; nobody independent labelled them, and they are not real users' answers. They over-sample hard cases, so these rates are not the rates of everyday practice.
- Plain text: no speech recognition errors, which real answers have.
- One model version, one prompt, one reasoning effort, English only, first answers only (no previous question or assessment in the message).
- n is small: one objective is 1.1 points of accuracy, and one false addressed is 2 points of that rate. Run 1 and run 2 differ by 2 objectives in accuracy and 3 in false addressed.
- The partial / not addressed boundary is a matter of reading; a reader with a looser idea of partial would score the model higher.
