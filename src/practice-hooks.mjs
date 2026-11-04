// How practice rounds (src/practice.mjs) reach follow-up exercises (src/practice-exercises.mjs) without importing
// them: the exercise module registers a dependency checker and an after-mutation listener here. This module imports
// nothing, so it is ready before either module uses it, whatever the import order.
// Until registration, a round linked to an exercise reads as stale (the safe default) and no listener runs.
export const exerciseHooks = { dependencyCurrent: () => false, changed: () => {} };
// dependencyCurrent(store, user, round): whether the exercise a round is linked to still supports it.
// changed(store, user, before, after, action, voice?): runs inside the transaction of a round's lifecycle or answer write.
export function registerExerciseHooks({ dependencyCurrent, changed }) {
  exerciseHooks.dependencyCurrent = dependencyCurrent;
  exerciseHooks.changed = changed;
}
