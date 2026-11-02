// Motion: highlight sweep, cards slotting in, and the string between devices going taut.
// With Reduce Motion everything renders in its final state.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const canObserve = 'IntersectionObserver' in window;
  const root = document.documentElement;
  const tautPath = animate => animate.getAttribute('values').split(';').pop();

  // Without motion: strings are drawn taut, nothing animates in.
  if (reduce || !canObserve) {
    document.querySelectorAll('animate[data-taut]').forEach(a => a.parentElement.setAttribute('d', tautPath(a)));
    return;
  }

  root.classList.add('js-sweep', 'js-motion');

  // Highlighter sweep: each marked word fills in once, left to right.
  document.querySelectorAll('[data-sweep]').forEach(block => {
    block.querySelectorAll('.hl').forEach((mark, i) => { mark.style.transitionDelay = `${120 + i * 140}ms`; });
  });

  // Cards slot in one after another within a group.
  document.querySelectorAll('[data-slot-group]').forEach(group => {
    group.querySelectorAll('.slot').forEach((card, i) => { card.style.transitionDelay = `${i * 70}ms`; });
  });

  const seen = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      const el = entry.target;
      el.classList.add('is-in');
      if (el.hasAttribute('data-string-group')) {
        el.querySelectorAll('animate[data-taut]').forEach((a, i) => {
          setTimeout(() => {
            if (typeof a.beginElement === 'function') a.beginElement();
            else a.parentElement.setAttribute('d', tautPath(a));
          }, 250 + i * 120);
        });
      }
      seen.unobserve(el);
    });
  }, { threshold: 0.25 });

  document.querySelectorAll('[data-sweep], [data-slot-group], [data-string-group]').forEach(el => seen.observe(el));
})();
