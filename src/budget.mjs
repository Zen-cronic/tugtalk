// One time budget per paid request (a recording, a voice round or a screen context), shared by all of its model calls.
// The hosting adapter answers a model request within 150 s; this budget ends 30 s earlier so the write, the commit and
// the response still fit. Behind the adapter the budget is also cut to what is left of that request's own deadline
// (budget_ms in the worker envelope), so time spent waiting for another request's model call is counted too.
// Every provider call is cut off when the budget runs out, and a step that cannot start with enough time left is
// refused before any network call, so it is never billed. A recording then saves what finished (a partial result);
// a voice round answers 502 and saves nothing, as for any failed reply. Either way the client hears back in time, and
// an exact retry replays the saved receipt instead of paying again.

export const MODEL_BUDGET_MS = 120_000;
export const ADAPTER_DEADLINE_MS = 150_000;
// The least time a step needs to be worth starting.
export const MIN_START_MS = { transcription: 10_000, analysis: 15_000, adjudication: 15_000, reply: 4_000, screen: 15_000 };
export const SKIPPED_FOR_TIME = 'Skipped: not enough time left in this request.';

export class BudgetRefused extends Error {
  constructor(step, remainingMs) {
    super(`Not enough time left for ${step} (${Math.round(remainingMs / 1000)} s).`);
    this.name = 'TimeoutError'; // clients treat this like a timeout: no retry is sent
    this.budgetRefused = true;
    this.step = step;
  }
}

// totalMs: the budget; clock: milliseconds (performance.now by default, a fake clock in tests).
export function createBudget({ totalMs = MODEL_BUDGET_MS, clock = () => performance.now() } = {}) {
  const started = clock();
  const total = Math.max(0, Number.isFinite(totalMs) ? totalMs : MODEL_BUDGET_MS);
  const remaining = () => Math.max(0, started + total - clock());
  return {
    totalMs: total,
    remaining,
    elapsed: () => clock() - started,
    // True when a step that needs minMs can still start.
    allows: minMs => remaining() >= minMs,
    // A fetch for one step: refused below minStartMs, and aborted when the budget runs out.
    fetch(fetchImpl, { step, minStartMs = 0 }) {
      return (url, init = {}) => {
        const left = remaining();
        if (left < Math.max(minStartMs, 1)) return Promise.reject(new BudgetRefused(step, left));
        const limit = AbortSignal.timeout(Math.max(1, Math.floor(left)));
        return fetchImpl(url, { ...init, signal: init.signal ? AbortSignal.any([init.signal, limit]) : limit });
      };
    }
  };
}

