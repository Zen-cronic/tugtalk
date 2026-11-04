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

Not run yet.
