// Highlighter sweep: each marked word fills in once, left to right, when its transcript scrolls into view.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const blocks = document.querySelectorAll('[data-sweep]');
  if (reduce || !('IntersectionObserver' in window) || !blocks.length) return;

  document.documentElement.classList.add('js-sweep');
  blocks.forEach(block => {
    block.querySelectorAll('.hl').forEach((mark, i) => { mark.style.transitionDelay = `${120 + i * 140}ms`; });
  });

  const seen = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-in');
      seen.unobserve(entry.target);
    });
  }, { threshold: 0.4 });
  blocks.forEach(block => seen.observe(block));
})();
