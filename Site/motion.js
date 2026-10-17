'use strict';
// Content is visible by default. Motion enhances entry without hiding pending sections.
(() => {
  if (!Element.prototype.animate) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const active = new Map();
  const seen = new WeakSet();
  const ease = 'cubic-bezier(.22, 1, .36, 1)';
  const animate = (element, distance = 16, delay = 0, duration = 560) => {
    if (reduced.matches || document.hidden || element.contains(document.activeElement)) return;
    active.get(element)?.cancel();
    const animation = element.animate([
      { opacity: 0, translate: `0 ${distance}px` },
      { opacity: 1, translate: '0 0' }
    ], { duration, delay, easing: ease, fill: 'backwards' });
    active.set(element, animation);
    const cleanup = () => { if (active.get(element) === animation) active.delete(element); };
    animation.addEventListener('finish', cleanup, { once: true });
    animation.addEventListener('cancel', cleanup, { once: true });
  };
  const settle = () => {
    for (const animation of active.values()) animation.cancel();
    active.clear();
  };

  // Animate the tile itself; pointer parallax remains on its outer wrapper.
  const heroItems = [...document.querySelectorAll('.hero-content > *')];
  const tiles = [...document.querySelectorAll('.ai-tile')];
  if (!location.hash && scrollY < 100) {
    heroItems.forEach((element, index) => animate(element, 14, index * 45));
    tiles.forEach((element, index) => animate(element, 0, 120 + index * 35, 700));
  }

  const sections = [...document.querySelectorAll(
    '.showcase, .connection-heading, .connection-grid, .connection-footer, ' +
    '.section-heading, .github-feature, .feature-card, .native-section > div, ' +
    '.native-facts > div, .steps > li, .faq-section > div, .closing'
  )];
  let observer;
  if ('IntersectionObserver' in window) {
    observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const element = entry.target;
        observer.unobserve(element);
        seen.add(element);
        // Skip sections above a restored scroll position or direct anchor target.
        if (entry.boundingClientRect.bottom <= 100) continue;
        const siblings = element.parentElement;
        const staggered = siblings.matches('.feature-grid, .native-facts, .steps');
        const delay = staggered ? [...siblings.children].indexOf(element) * 55 : 0;
        animate(element, 18, delay);
      }
    }, { rootMargin: '0px 0px 40px 0px', threshold: 0 });
  }
  const observe = () => {
    observer?.disconnect();
    if (!reduced.matches) sections.filter(element => !seen.has(element)).forEach(element => observer?.observe(element));
  };
  observe();
  reduced.addEventListener('change', () => { settle(); observe(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) settle(); });
  window.addEventListener('pagehide', settle);
  // Keyboard navigation never has to wait for an entrance effect.
  document.addEventListener('focusin', event => {
    for (const [element, animation] of active) {
      if (element.contains(event.target)) { animation.cancel(); active.delete(element); }
    }
  });
  document.addEventListener('nativeagent:preview', event => {
    if (event.detail?.panel instanceof HTMLElement) animate(event.detail.panel, 8, 0, 300);
  });
  document.querySelectorAll('details').forEach(details => {
    details.addEventListener('toggle', () => {
      const paragraphs = [...details.querySelectorAll(':scope > p')];
      if (details.open) paragraphs.forEach((paragraph, index) => animate(paragraph, 5, index * 25, 280));
      else paragraphs.forEach(paragraph => { active.get(paragraph)?.cancel(); active.delete(paragraph); });
    });
  });
})();
