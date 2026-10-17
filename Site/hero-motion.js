'use strict';
// A small response to the pointer, with no idle animation or touch interception.
(() => {
  const scene = document.querySelector('[data-orbit]');
  if (!scene) return;
  const cards = [...scene.querySelectorAll('[data-depth]')].map(element => ({
    element, depth: Math.min(24, Math.max(0, Number(element.dataset.depth) || 0))
  }));
  const motion = matchMedia('(prefers-reduced-motion: no-preference)');
  const pointer = matchMedia('(hover: hover) and (pointer: fine) and (min-width: 1201px)');
  let visible = true, frame = 0, previousTime = 0;
  let x = 0, y = 0, targetX = 0, targetY = 0;
  const enabled = () => motion.matches && pointer.matches && visible && !document.hidden;
  const paint = () => cards.forEach(({ element, depth }) => {
    element.style.transform = `translate3d(${(x * depth).toFixed(2)}px, ${(y * depth).toFixed(2)}px, 0)`;
  });
  const reset = () => {
    cancelAnimationFrame(frame); frame = 0; previousTime = 0;
    x = y = targetX = targetY = 0;
    cards.forEach(({ element }) => element.style.removeProperty('transform'));
  };
  const tick = time => {
    frame = 0;
    if (!enabled()) { reset(); return; }
    // Time-based easing keeps the same feel on both 60 Hz and high-refresh screens.
    const elapsed = previousTime ? Math.min(time - previousTime, 64) : 16;
    previousTime = time;
    const ease = 1 - Math.exp(-elapsed / 110);
    x += (targetX - x) * ease; y += (targetY - y) * ease;
    if (Math.abs(targetX - x) + Math.abs(targetY - y) < .001) {
      x = targetX; y = targetY; previousTime = 0; paint(); return;
    }
    paint(); frame = requestAnimationFrame(tick);
  };
  const animate = () => { if (!frame && enabled()) frame = requestAnimationFrame(tick); };
  scene.addEventListener('pointermove', event => {
    if (!enabled() || event.pointerType === 'touch') return;
    const bounds = scene.getBoundingClientRect();
    targetX = Math.max(-1, Math.min(1, (event.clientX - bounds.left) / bounds.width * 2 - 1));
    targetY = Math.max(-1, Math.min(1, (event.clientY - bounds.top) / bounds.height * 2 - 1));
    animate();
  }, { passive: true });
  scene.addEventListener('pointerleave', () => { targetX = targetY = 0; animate(); }, { passive: true });
  scene.addEventListener('pointercancel', reset, { passive: true });
  window.addEventListener('blur', reset);
  window.addEventListener('pagehide', reset);
  document.addEventListener('visibilitychange', reset);
  motion.addEventListener('change', reset);
  pointer.addEventListener('change', reset);
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(entries => {
      visible = entries[0].isIntersecting;
      if (!visible) reset();
    }).observe(scene);
  }
})();
