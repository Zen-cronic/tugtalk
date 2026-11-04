# Muse scheduled read: evidence

On November 1, 2026, a scheduled Muse task read TugTalk's hosted service through the custom connector, with no one prompting it at run time, and suggested one practice from what it read. The service's own request log holds both reads. This page sets out what happened, the matching log rows, and what the run does and doesn't prove.

## What a scheduled task is

A Muse scheduled task is a prompt that Muse stores and runs by itself at a set time, then posts the result in the chat where it was created. This one was a one-off (`runonce`) task, registered in Muse at 16:28 EST (21:28 UTC) to run at 16:40 EST (21:40 UTC). Muse listed it as task `synthetic-coaching-overview-2026-11-01`, America/Toronto time zone.

The task prompt told Muse to:
- fetch nothing until the scheduled time;
- read a fresh overview, choose a goal only from that fresh state, then read that goal's focused context;
- suggest one optional exercise, with the evidence behind it;
- report `as_of`, `snapshot_revision` and the request id for each call, and quote any error exactly.

It also told Muse to make no POST or PATCH requests, record no check-ins or completions, and use no other connector, memory or undocumented route.

## What Muse fetched

Both calls use routes documented in the README's "API contract" table and in the service's `/openapi.json`, authenticated with the connector's Bearer key.

| # | Route | Status | Request id | `as_of` (UTC) | `as_of` (EST) |
|---|---|---|---|---|---|
| 1 | `GET /v1/overview` | 200 | `cb3396f7-f53a-4fcd-a514-fbec6c35fc0b` | 2026-11-01 21:40:13.777 | 2026-11-01 16:40:13.777 |
| 2 | `GET /v1/goals/41412a74-2a84-4094-aed7-a32082c705c9/context` | 200 | `6938291c-5eb5-4e26-adbd-334770a0ea58` | 2026-11-01 21:40:24.994 | 2026-11-01 16:40:24.994 |

Both responses carried the same `snapshot_revision` (`9778fd27…b48b4e`), which is consistent with no change to the record between the two reads.

From the overview, Muse chose the goal "Answer clearly" (`41412a74…`, version 2), the only goal with no completions and a skipped check-in. It then suggested an optional two-minute drill: answer in two sentences, main point first, then one supporting detail. It cited the overview counts, the skipped "ran out of time" check-in and the goal's assigned exercise. It said the suggestion was not recorded and claimed no measured improvement.

## Server log rows

The service writes one row to its `requests` table for every request, keyed by the same id it returns in `X-Request-Id` (`src/store.mjs`, `src/server.mjs`). We read a copy of the hosted database, taken on November 4 before a redeploy, read-only:

```sql
select id, method, path, status, created_at from requests
where id in ('cb3396f7-f53a-4fcd-a514-fbec6c35fc0b',
             '6938291c-5eb5-4e26-adbd-334770a0ea58');
```

| id | method | path | status | created_at (UTC) | created_at (EST) |
|---|---|---|---|---|---|
| `cb3396f7-f53a-4fcd-a514-fbec6c35fc0b` | GET | `/v1/overview` | 200 | 2026-11-01T21:40:13.789Z | 16:40:13.789 |
| `6938291c-5eb5-4e26-adbd-334770a0ea58` | GET | `/v1/goals/41412a74-2a84-4094-aed7-a32082c705c9/context` | 200 | 2026-11-01T21:40:25.007Z | 16:40:25.007 |

Both ids, methods, paths and statuses match exactly what Muse reported. Each `created_at` falls 12 to 13 ms after the response's `as_of`, because the log row is written as the response is sent. Both rows carry a user id, so both requests were authenticated.

The same table shows:
- **Nothing was fetched early.** Between registration (21:28 UTC, 16:28 EST) and 21:40:13 UTC (16:40:13 EST) there were no requests at all.
- **Only these two requests in the run.** From 21:28 UTC to 21:50:54 UTC (16:28 to 16:50:54 EST) the table holds exactly these two rows and no request other than a GET. Muse had posted its suggestion before 21:43 UTC (16:43 EST).
- **Nothing was written.** The `receipts` table, which records every write, has no row in that window. Its latest earlier row is from October 30.

## What this proves

- A scheduled Muse task, running without a prompt at run time, read TugTalk's state through the documented connector routes.
- The reads were fresh. Both request ids were new, both arrived after the scheduled time, and the service logged each one 12 to 13 ms after the `as_of` Muse reported.
- Muse grounded its suggestion in the retrieved record, not in chat history, and wrote nothing back.

The goal choice alone proves nothing, because older chat history would have pointed to the same goal. The proof is the two new request ids and their matching server rows.

## What it doesn't prove

- **Synthetic test account.** The record belongs to one synthetic account, not a real user.
- **Watch capture isn't part of this run.** This run reads the shared record; it says nothing about capture on the Apple Watch. Most watch runs used the watchOS simulator; on a real Apple Watch, one capture has succeeded (Nov 4, 13:08 EST), and TestFlight builds have been tested on a watch.
- **One run.** One scheduled run gives no reliability rate.
- **Conditions.** A laptop with the browser open was running at the time. Delivery to a phone and a run with the laptop closed were not observed.
- **Pull, not push.** The task was set up with an explicit prompt, and Muse pulled the record on its own schedule. TugTalk never wakes Muse, and quiet hours, snooze and a product-owned cadence don't exist yet.
