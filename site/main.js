// Demo link: one value, data-demo-url on <body>. Until it is set, "Watch the demo" scrolls to the example.
(() => {
  const url = (document.body.dataset.demoUrl || '').trim();
  if (!url) return;
  document.querySelectorAll('[data-demo-link]').forEach(link => {
    link.href = url;
    link.target = '_blank';
    link.rel = 'noopener';
  });
})();

// Motion. Without JS or with Reduce Motion the page renders in its final state, and every
// animated section ends on that same state. Only transform and opacity animate; scrolling stays native.
(() => {
  const root = document.documentElement;
  const $ = (sel, el = document) => el.querySelector(sel);
  const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const tautPath = animate => animate.getAttribute('values').split(';').pop();
  const kinds = ['filler', 'hedge', 'restart'];
  const kindOf = el => kinds.find(k => ['hl', 'chip', 'tile'].some(p => el.classList.contains(`${p}-${k}`)));

  // Words become spans so the hero can type them and a count can point at its words.
  const wrapWords = block => {
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(node => {
      if (!node.textContent.trim() || node.parentElement.closest('.w')) return;
      const frag = document.createDocumentFragment();
      node.textContent.split(/(\s+)/).forEach(part => {
        if (!part) return;
        if (/^\s+$/.test(part)) { frag.append(part); return; }
        const w = document.createElement('span');
        w.className = 'w';
        w.textContent = part;
        frag.append(w);
      });
      node.replaceWith(frag);
    });
  };
  $$('.transcript, .frag').forEach(wrapWords);

  // Hover a count to see the words it counted (opacity only, so it also runs with Reduce Motion).
  $$('.chip, .tile').forEach(el => {
    const kind = kindOf(el);
    const scope = el.closest('.hero-card, .measured-grid');
    if (!kind || !scope || !$('.transcript .hl', scope)) return;
    el.addEventListener('pointerenter', () => scope.classList.add(`show-${kind}`));
    el.addEventListener('pointerleave', () => scope.classList.remove(`show-${kind}`));
  });

  // Rail layout: each stop sits at its step's thumbnail. Layout only, so it also runs with Reduce Motion.
  const railLayout = () => {
    const how = $('.how'), rail = how && $('.rail', how);
    if (!rail) return { off: true, stops: [] };
    const off = getComputedStyle(rail).display === 'none';
    const vertical = !off && window.matchMedia('(max-width: 760px)').matches;
    if (off) return { off, vertical, stops: [] };
    const wr = $('.track-wrap', how).getBoundingClientRect();
    const stops = $$('.step', how).map(s => {
      const t = $('.thumb', s).getBoundingClientRect();
      return vertical ? t.top + t.height / 2 - wr.top : t.left + t.width / 2 - wr.left;
    });
    rail.style.setProperty('--a', `${stops[0]}px`);
    $$('.rail-stop', rail).forEach((el, i) => {
      el.style.left = vertical ? '' : `${stops[i]}px`;
      el.style.top = vertical ? `${stops[i]}px` : '';
    });
    return { off, vertical, stops };
  };
  railLayout();
  root.classList.add('js-rail');

  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduce || !('IntersectionObserver' in window) || !Element.prototype.animate) {
    $$('animate[data-taut]').forEach(a => a.parentElement.setAttribute('d', tautPath(a)));
    root.classList.remove('js-motion', 'js-sweep');
    $$('.rail-stop').forEach(el => el.classList.add('is-on'));
    addEventListener('resize', railLayout);
    return;
  }
  root.classList.add('js-sweep', 'js-motion');

  const once = (el, fn, options = { threshold: 0.25 }) => {
    if (!el) return;
    const io = new IntersectionObserver(entries => entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      io.disconnect();
      fn(entry.target);
    }), options);
    io.observe(el);
  };
  const pluck = el => el && $$('animate[data-taut]', el).forEach(a => {
    if (typeof a.beginElement === 'function') a.beginElement();
    else a.parentElement.setAttribute('d', tautPath(a));
  });
  const bump = (el, delay = 0) => el && el.animate(
    [{ transform: 'none' }, { transform: 'translateY(-5px)', offset: 0.4 }, { transform: 'none' }],
    { duration: 320, delay, easing: 'cubic-bezier(.3, 1.5, .6, 1)' });
  const visible = el => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.bottom > 0 && r.top < innerHeight;
  };

  // Steps that unlock in the same moment still play one after another.
  let free = 0;
  const queue = (fn, gap = 260) => {
    const now = performance.now();
    const at = Math.max(now, free);
    free = at + gap;
    setTimeout(fn, at - now);
  };

  // Tug: looks at the cursor (eyes and face, with a lean of at most 5 degrees), follows the typing,
  // winces at a filler, nods when its line lands and tugs its string when a section completes.
  const tugs = $$('svg.tug').map(svg => ({ svg, eyes: $('.tug-eyes', svg), face: $('.t-line', svg) })).filter(t => t.eyes);
  const tugOf = svg => tugs.find(t => t.svg === svg);
  const lookAt = (t, x, y) => {
    const r = t.svg.getBoundingClientRect();
    if (!r.width || r.bottom < 0 || r.top > innerHeight) return;
    const dx = x - (r.left + r.width / 2), dy = y - (r.top + r.height * 0.45);
    const d = Math.hypot(dx, dy) || 1, k = Math.min(1, d / 200);
    const ex = dx / d * 3.6 * k, ey = dy / d * 2.8 * k;
    t.eyes.style.translate = `${ex.toFixed(2)}px ${ey.toFixed(2)}px`;
    if (t.face) t.face.style.translate = `${(ex * 0.45).toFixed(2)}px ${(ey * 0.45).toFixed(2)}px`;
    t.svg.style.rotate = `${clamp(dx / 90, -5, 5).toFixed(2)}deg`;
  };
  const rest = t => {
    if (!t) return;
    t.eyes.style.translate = '';
    if (t.face) t.face.style.translate = '';
    t.svg.style.rotate = '';
  };
  let lastPointer = -1e4;
  const pointerIdle = () => performance.now() - lastPointer > 1500;
  if (window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
    let px = 0, py = 0, frame = 0;
    addEventListener('pointermove', e => {
      px = e.clientX; py = e.clientY; lastPointer = performance.now();
      if (!frame) frame = requestAnimationFrame(() => { frame = 0; tugs.forEach(t => lookAt(t, px, py)); });
    }, { passive: true });
    document.addEventListener('pointerleave', () => tugs.forEach(rest));
  }
  // Without a cursor, Tug glances the way the page is scrolling.
  let lastY = scrollY, glance = 0;
  addEventListener('scroll', () => {
    const dir = Math.sign(scrollY - lastY);
    lastY = scrollY;
    if (!dir || !pointerIdle()) return;
    tugs.forEach(t => { t.eyes.style.translate = `0px ${dir * 2}px`; });
    clearTimeout(glance);
    glance = setTimeout(() => tugs.forEach(t => { t.eyes.style.translate = ''; }), 420);
  }, { passive: true });
  const gazeAt = (svg, el) => {
    const t = tugOf(svg);
    if (!t || !el || !pointerIdle()) return;
    const r = el.getBoundingClientRect();
    lookAt(t, r.left + r.width / 2, r.top + r.height / 2);
  };
  const tug = svg => svg && svg.animate([
    { transform: 'none' },
    { transform: 'translate(-3px, 2px) rotate(-5deg)', offset: 0.22 },
    { transform: 'translate(2px, -1px) rotate(2deg)', offset: 0.58 },
    { transform: 'none' }
  ], { duration: 620, easing: 'ease-out' });
  const wince = svg => {
    const t = tugOf(svg);
    if (!t) return;
    t.eyes.animate([{ transform: 'scaleY(1)' }, { transform: 'scaleY(.12)', offset: 0.4 }, { transform: 'scaleY(1)' }], { duration: 280, easing: 'ease-out' });
    svg.animate([{ transform: 'none' }, { transform: 'translateX(-2px)', offset: 0.3 }, { transform: 'translateX(2px)', offset: 0.65 }, { transform: 'none' }], { duration: 280 });
  };
  const nod = svg => svg && svg.animate([
    { transform: 'none' },
    { transform: 'translateY(3px) rotate(4deg)', offset: 0.35 },
    { transform: 'translateY(-1px) rotate(-1deg)', offset: 0.7 },
    { transform: 'none' }
  ], { duration: 560, easing: 'ease-out' });
  const heroTug = $('.tug-hero');
  if (heroTug) heroTug.addEventListener('pointerdown', () => tug(heroTug));
  $$('.brand, .foot-brand').forEach(b => b.addEventListener('pointerenter', () => tug($('.glyph', b))));

  // Counters: digits roll one value at a time, and the label follows ("1 filler", "2 fillers").
  // The final value and label stay in the markup for assistive technology.
  const labelOf = holder => {
    if (!holder) return null;
    const word = holder.textContent.trim();
    const span = document.createElement('span');
    span.setAttribute('aria-hidden', 'true');
    span.textContent = word;
    const sr = document.createElement('span');
    sr.className = 'visually-hidden';
    sr.textContent = word;
    holder.textContent = '';
    holder.append(span, sr);
    return span;
  };
  const chipLabel = chip => {
    const node = $('b', chip) && $('b', chip).nextSibling;
    if (!node || node.nodeType !== 3) return null;
    const text = node.textContent, word = text.trim();
    const span = document.createElement('span');
    span.className = 'lbl';
    span.setAttribute('aria-hidden', 'true');
    span.textContent = word;
    const sr = document.createElement('span');
    sr.className = 'visually-hidden';
    sr.textContent = word;
    node.replaceWith(document.createTextNode(text.slice(0, text.indexOf(word))), span, sr);
    return span;
  };
  const counter = (holder, label) => {
    const final = holder.textContent.trim();
    if (!/^\d+$/.test(final)) return null;
    const reel = document.createElement('span');
    reel.className = 'reel';
    reel.setAttribute('aria-hidden', 'true');
    const strips = [...final].map(d => {
      const col = document.createElement('span');
      col.className = 'reel-col';
      col.innerHTML = `<span class="reel-size">${d}</span><span class="reel-strip">${'0123456789'.split('').map(n => `<span>${n}</span>`).join('')}</span>`;
      reel.append(col);
      return $('.reel-strip', col);
    });
    const sr = document.createElement('span');
    sr.className = 'visually-hidden';
    sr.textContent = final;
    holder.textContent = '';
    holder.append(reel, sr);
    holder.classList.add('is-ready');
    const word = label ? label.textContent : '';
    const singular = word.replace(/s$/, ''), plural = word.endsWith('s') ? word : `${word}s`;
    const api = {
      final: Number(final),
      value: Number(final),
      set(n, now = false) {
        api.value = n;
        const s = String(n).padStart(strips.length, ' ').slice(-strips.length);
        strips.forEach((strip, i) => {
          strip.style.opacity = s[i] === ' ' ? '0' : '';
          if (s[i] !== ' ') strip.style.setProperty('--d', s[i]);
        });
        // The label changes halfway through the roll, as the new digit arrives.
        if (label) {
          clearTimeout(api.timer);
          const word = n === 1 ? singular : plural;
          if (now) label.textContent = word;
          else api.timer = setTimeout(() => { label.textContent = word; }, 90);
        }
      },
      tick(d = 1) { api.set(api.value + d); }
    };
    return api;
  };
  const chipCounter = chip => counter($('b', chip), chipLabel(chip));

  // Card groups slot in once they reach the viewport.
  const seen = new IntersectionObserver(entries => entries.forEach(entry => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('is-in');
    seen.unobserve(entry.target);
  }), { threshold: 0.4 });
  $$('[data-slot-group]').forEach(el => seen.observe(el));

  // Watch thumbnails: ready, then recording with the red ring, then sent; they end back on ready.
  const recordWatch = (watch, sendAfter, readyAfter) => {
    if (!watch) return;
    watch.classList.add('is-rec');
    if (sendAfter) setTimeout(() => watch.classList.add('is-sent'), sendAfter);
    if (readyAfter) setTimeout(() => watch.classList.remove('is-rec', 'is-sent'), readyAfter);
  };

  // Hero: a short watch beat (Record, the string carries the sound, Stop), a pulse along the
  // string, then the answer is typed once. Each count ticks as its word is highlighted.
  const hero = $('.hero-stage');
  if (hero) {
    const block = $('[data-stream]', hero), words = $$('.w', block), marks = $$('.hl', block);
    hero.classList.add('is-running');
    const watch = $('.hero-watch .watch', hero), link = $('.hero-link', hero);
    const counts = {};
    $$('.hero-card .chip', hero).forEach(chip => {
      const c = chipCounter(chip);
      if (c) { c.set(0, true); counts[kindOf(chip)] = c; }
    });
    if (words[0]) words[0].classList.add('is-shown');
    const step = Number(block.dataset.stream) || 55;
    const wide = () => link && getComputedStyle(link).display !== 'none';

    const vibrate = () => {
      if (wide()) {
        $('.s-h', link).animate(
          [1, -0.8, 0.6, -0.45, 0.3, -0.15, 1].map(v => ({ transform: `scaleY(${v})` })),
          { duration: 560, easing: 'linear' });
      } else {
        $('.t-string', heroTug).animate(
          [1, 1.4, 0.7, 1.25, 0.85, 1].map(v => ({ transform: `scaleY(${v})` })),
          { duration: 560, easing: 'linear' });
      }
    };
    const pulse = async () => {
      if (wide()) {
        pluck(link);
        await sleep(260);
        $('.bead', link).animate([
          { transform: 'translateX(0)', opacity: 0 },
          { transform: 'translateX(0)', opacity: 1, offset: 0.1 },
          { transform: 'translateX(100%)', opacity: 1, offset: 0.9 },
          { transform: 'translateX(100%)', opacity: 0 }
        ], { duration: 380, easing: 'ease-in-out' });
        await sleep(380);
      } else {
        // The string runs from the can to the watch; the pulse travels back to Tug.
        const path = $('.t-string', heroTug), bead = $('.t-bead', heroTug), len = path.getTotalLength();
        const n = 14;
        bead.animate(Array.from({ length: n }, (_, i) => {
          const pt = path.getPointAtLength(len * (1 - i / (n - 1)));
          return { transform: `translate(${pt.x}px, ${pt.y}px)`, opacity: i === 0 || i === n - 1 ? 0 : 1 };
        }), { duration: 420, easing: 'linear' });
        await sleep(420);
      }
    };

    (async () => {
      await sleep(350);
      recordWatch(watch);
      vibrate();
      await sleep(600);
      if (watch) watch.classList.add('is-sent');
      await pulse();
      words.forEach((w, i) => {
        if (i === 0) return;
        setTimeout(() => {
          w.classList.add('is-shown');
          if (i % 2 === 0) gazeAt(heroTug, w);
        }, (i - 1) * step);
      });
      marks.forEach(mark => {
        const i = words.indexOf($('.w', mark));
        setTimeout(() => {
          mark.classList.add('is-lit');
          const k = kindOf(mark);
          if (counts[k]) counts[k].tick();
          if (k === 'filler') wince(heroTug);
        }, Math.max(0, i - 1) * step + 60);
      });
      await sleep((words.length - 1) * step + 420);
      block.classList.add('is-done');
      hero.classList.add('is-said');
      nod(heroTug);
      pluck(hero);
      if (pointerIdle()) rest(tugOf(heroTug));
      await sleep(700);
      if (watch) watch.classList.remove('is-rec', 'is-sent');
    })();
  }

  // Scroll scenes share one passive listener and run only while near the viewport.
  const scenes = new Set(), allScenes = [];
  let ticking = false;
  const request = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { ticking = false; scenes.forEach(s => s.update()); });
  };
  addEventListener('scroll', request, { passive: true });
  let resizeTimer = 0;
  addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { allScenes.forEach(s => s.measure()); request(); }, 120);
  });
  const addScene = (el, scene) => {
    allScenes.push(scene);
    scene.measure();
    new IntersectionObserver(entries => entries.forEach(e => {
      if (e.isIntersecting) { scenes.add(scene); request(); } else scenes.delete(scene);
    }), { rootMargin: '30% 0px' }).observe(el);
  };

  // How one answer gets counted: a bead carries the answer along the string. Each card keeps its
  // content; one small thing moves as the bead reaches it.
  const how = $('.how');
  if (how) {
    const wrap = $('.track-wrap', how);
    const bead = $('.rail-bead', how), fill = $('.rail-fill', how), line = $('.rail-line', how);
    const stopEls = $$('.rail-stop', how), steps = $$('.step', how);
    const railTug = () => $$('.rail-tug svg', how).find(s => s.getBoundingClientRect().width);
    let stops = [], vertical = false, off = false, maxPos = -Infinity, finished = false;
    const lit = new Set();

    const light = i => {
      if (lit.has(i)) return;
      lit.add(i);
      queue(() => {
        const step = steps[i];
        step.classList.add('is-on');
        if (stopEls[i]) stopEls[i].classList.add('is-on');
        if (i === 0) recordWatch($('.thumb-watch .watch', step), 1000, 2000);
        if (i === 2) $$('.thumb-chips .chip', step).forEach((chip, j) => bump(chip, j * 120));
        if (i === steps.length - 1 && !finished) { finished = true; setTimeout(() => tug(railTug()), 900); }
      }, 320);
    };

    const scene = {
      measure() {
        ({ off, vertical, stops } = railLayout());
        if (off) return;
        const last = maxPos;
        maxPos = -Infinity;
        this.place(clamp(last, stops[0], stops[stops.length - 1]));
      },
      place(pos) {
        if (pos <= maxPos) return;
        maxPos = pos;
        const run = pos - stops[0];
        const len = vertical ? line.offsetHeight : line.offsetWidth;
        bead.style.transform = vertical ? `translateY(${run}px)` : `translateX(${run}px)`;
        fill.style.transform = vertical ? `scaleY(${clamp(run / len)})` : `scaleX(${clamp(run / len)})`;
      },
      update() {
        if (off) return;
        const vh = innerHeight, wr = wrap.getBoundingClientRect();
        const first = stops[0], last = stops[stops.length - 1];
        let raw;
        if (vertical) raw = vh * 0.62 - wr.top;
        else {
          // Starts once the cards' thumbnails are on screen; finishes when the whole track is.
          const t = $('.thumb', steps[0]).getBoundingClientRect();
          const mid = t.top + t.height / 2, a = vh * 0.82;
          const b = Math.min(a - 120, vh - 24 - (wr.bottom - mid));
          raw = first + ((a - mid) / (a - b)) * (last - first);
        }
        if (raw < first) return;
        this.place(Math.min(raw, last));
        stops.forEach((s, i) => { if (maxPos >= s - 2) light(i); });
      }
    };
    addScene(how, scene);
    // Two columns (tablet): no rail, so each step lights as it comes into view.
    steps.forEach((step, i) => once(step, () => { if (off) light(i); }, { rootMargin: '0px 0px -30% 0px' }));
  }

  // What one answer shows: the sentence is already settled. Each highlighted word flies into its
  // card, and that count ticks up as it lands. Words per minute settles last.
  const measured = $('.measured');
  if (measured) {
    const block = $('.transcript-lg', measured), tugAsk = $('.tug-ask', measured);
    const tiles = {};
    $$('.tile', measured).forEach(tile => {
      const k = kindOf(tile) || 'wpm';
      const num = $('.tally-num', tile);
      const c = counter(num, k === 'wpm' ? null : labelOf($('.tally-label', tile)));
      if (c) { c.set(0, true); tiles[k] = { c, tile, num }; }
    });
    const mini = $('.mini-tally', measured), minis = {};
    if (mini) $$('.chip', mini).forEach(chip => {
      const c = chipCounter(chip);
      if (c) { c.set(0, true); minis[kindOf(chip)] = { c, chip }; }
    });
    const fly = (from, to, kind) => {
      const a = from.getBoundingClientRect(), b = to.getBoundingClientRect();
      const g = document.createElement('span');
      g.className = `ghost hl hl-${kind}`;
      g.setAttribute('aria-hidden', 'true');
      g.textContent = from.textContent;
      const cs = getComputedStyle(from);
      Object.assign(g.style, { left: `${a.left}px`, top: `${a.top}px`, fontFamily: cs.fontFamily, fontSize: cs.fontSize, fontWeight: cs.fontWeight, letterSpacing: cs.letterSpacing, padding: cs.padding, borderRadius: cs.borderRadius, lineHeight: `${a.height}px`, color: cs.color });
      document.body.append(g);
      const dx = b.left + b.width / 2 - (a.left + a.width / 2), dy = b.top + b.height / 2 - (a.top + a.height / 2);
      g.animate([
        { transform: 'none', opacity: 1 },
        { transform: `translate(${dx}px, ${dy}px)`, opacity: 1, offset: 0.82 },
        { transform: `translate(${dx}px, ${dy}px)`, opacity: 0 }
      ], { duration: 520, easing: 'cubic-bezier(.5, 0, .3, 1)' }).onfinish = () => g.remove();
    };
    once(block, async () => {
      for (const mark of $$('.hl', block)) {
        const k = kindOf(mark), tile = tiles[k], m = minis[k];
        const target = tile && visible(tile.tile) ? tile.num : m && visible(m.chip) ? $('b', m.chip) : tile && tile.num;
        gazeAt(tugAsk, mark);
        if (target) fly(mark, target, k);
        await sleep(440);
        if (tile) { tile.c.tick(); bump(tile.tile); }
        if (m) { m.c.tick(); bump(m.chip); }
        await sleep(160);
      }
      if (tiles.wpm) tiles.wpm.c.set(tiles.wpm.c.final);
      await sleep(600);
      nod(tugAsk);
      if (pointerIdle()) rest(tugOf(tugAsk));
    }, { threshold: 0.45 });
    // Hand off: while the big cards are on screen, the mini tally steps aside.
    if (mini) new IntersectionObserver(([e]) => mini.classList.toggle('is-handed', e.isIntersecting), { threshold: 0.2 }).observe($('.tally', measured));
  }

  // Devices: the string carries the record from the watch to the Mac to the phone.
  const devices = $('.devices');
  if (devices) {
    const stage = $('.devices-stage', devices), pin = $('.devices-pin', devices);
    const objs = $$('.lineup .obj', devices), links = $$('.lineup .string-link', devices);
    const caps = $$('.phase-cap span', devices);
    const watch = $('.obj-watch .watch', devices);
    let pinned = false, top = 80, maxP = -1, reached = -1, finished = false;

    const activate = k => {
      objs.forEach((o, i) => { o.classList.toggle('is-on', i === k); o.classList.toggle('is-done', i < k); });
      caps.forEach((c, i) => c.classList.toggle('is-on', i === k));
      if (k === 0) recordWatch(watch);
      if (k === 1) {
        if (watch) { watch.classList.add('is-sent'); setTimeout(() => watch.classList.remove('is-rec', 'is-sent'), 900); }
        bump($('.ring-label', devices), 150);
        bump($('.vc-q', devices), 300);
      }
      if (k === 2) $$('.obj-phone .bub', devices).forEach((b, j) => bump(b, 120 + j * 220));
    };
    const complete = () => {
      if (finished) return;
      finished = true;
      objs.forEach(o => { o.classList.remove('is-on'); o.classList.add('is-done'); });
      caps.forEach(c => c.classList.remove('is-on'));
      tug($('.voice-card .glyph', devices));
      pluck($('.lineup', devices));
    };
    const runBead = (link, b) => {
      $$('.bead', link).forEach(el => {
        el.style.transform = el.classList.contains('bead-v') ? `translateY(${b * 100}%)` : `translateX(${b * 100}%)`;
      });
      link.classList.toggle('is-run', b > 0 && b < 1);
    };
    const travel = async link => {
      pluck(link);
      link.classList.add('is-run');
      const beadEl = $$('.bead', link).find(el => getComputedStyle(el).display !== 'none');
      const axis = beadEl && beadEl.classList.contains('bead-v') ? 'Y' : 'X';
      if (beadEl) beadEl.animate([{ transform: `translate${axis}(0)` }, { transform: `translate${axis}(100%)` }], { duration: 600, easing: 'ease-in-out', fill: 'forwards' });
      await sleep(620);
      link.classList.remove('is-run');
    };
    const on = i => {
      for (let k = reached + 1; k <= i; k++) {
        const moves = k > 0 && !pinned;
        queue(async () => {
          if (moves) await travel(links[k - 1]);
          activate(k);
          if (k === objs.length - 1 && !pinned) setTimeout(complete, 1900);
        }, moves ? 900 : 160);
      }
      reached = Math.max(reached, i);
    };

    const scene = {
      measure() {
        const wide = window.matchMedia('(min-width: 1081px)').matches;
        stage.style.height = '';
        pinned = wide && pin.offsetHeight + 120 <= innerHeight;
        devices.classList.toggle('is-pinned', pinned);
        // A sticky box stays inside its parent's content box, so the stage gets real height for the travel.
        stage.style.height = pinned ? `${pin.offsetHeight + innerHeight}px` : '';
        top = Math.max(76, (innerHeight - pin.offsetHeight) / 2 + 28);
        pin.style.top = pinned ? `${top}px` : '';
        if (!pinned) links.forEach(l => $$('.bead', l).forEach(el => { el.style.transform = ''; }));
      },
      update() {
        if (!pinned) return;
        const r = stage.getBoundingClientRect();
        const raw = (top - r.top) / (stage.offsetHeight - pin.offsetHeight);
        if (raw < -0.04) return;
        const p = clamp(raw);
        if (p <= maxP) return;
        maxP = p;
        on(0);
        if (p > 0.08 && !links[0].dataset.taut) { links[0].dataset.taut = '1'; pluck(links[0]); }
        runBead(links[0], clamp((p - 0.12) / 0.24));
        if (p >= 0.38) on(1);
        if (p > 0.46 && !links[1].dataset.taut) { links[1].dataset.taut = '1'; pluck(links[1]); }
        runBead(links[1], clamp((p - 0.5) / 0.24));
        if (p >= 0.76) on(2);
        if (p >= 0.94) setTimeout(complete, 300);
      }
    };
    addScene(stage, scene);
    // Unpinned (narrow or short screens): each device lights as it reaches the reading line.
    objs.forEach((obj, i) => once(obj, () => { if (!pinned) on(i); }, { rootMargin: '0px 0px -35% 0px' }));
  }
})();
