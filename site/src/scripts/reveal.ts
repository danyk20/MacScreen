/** Reveal-on-scroll, plus pausing looping illustrations while they are off screen or the tab is hidden. */
document.documentElement.classList.add('js');

const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

const revealTargets = document.querySelectorAll<HTMLElement>('[data-reveal]');
if (reduced || !('IntersectionObserver' in window)) {
  revealTargets.forEach((el) => el.classList.add('is-visible'));
} else {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add('is-visible');
          io.unobserve(e.target);
        }
      }
    },
    { rootMargin: '0px 0px -12% 0px', threshold: 0.12 },
  );
  revealTargets.forEach((el) => io.observe(el));
}

// Looping illustrations: running only while visible.
const loops = document.querySelectorAll<HTMLElement>('[data-loop]');
if (loops.length && 'IntersectionObserver' in window) {
  const state = new WeakMap<Element, boolean>();
  const apply = (el: Element) => {
    const run = (state.get(el) ?? true) && !document.hidden;
    el.classList.toggle('is-paused', !run);
  };
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) { state.set(e.target, e.isIntersecting); apply(e.target); }
  }, { threshold: 0.05 });
  loops.forEach((el) => io.observe(el));
  document.addEventListener('visibilitychange', () => loops.forEach(apply));
}
