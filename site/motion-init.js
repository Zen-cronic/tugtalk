if (!matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window && Element.prototype.animate) document.documentElement.classList.add('js-motion', 'js-sweep');
