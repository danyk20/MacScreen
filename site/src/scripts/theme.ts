/** Theme toggle. The initial theme is applied by the inline script in Base.astro before first paint. */
const KEY = 'ms-theme';
const root = document.documentElement;

function effective(): 'light' | 'dark' {
  const set = root.dataset.theme;
  if (set === 'light' || set === 'dark') return set;
  return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function sync(button: HTMLButtonElement): void {
  const dark = effective() === 'dark';
  button.setAttribute('aria-pressed', String(dark));
  button.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme');
}

document.querySelectorAll<HTMLButtonElement>('[data-theme-toggle]').forEach((button) => {
  sync(button);
  button.addEventListener('click', () => {
    const next = effective() === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem(KEY, next); } catch { /* private mode: the choice just lasts for this page */ }
    document.querySelectorAll<HTMLButtonElement>('[data-theme-toggle]').forEach(sync);
  });
});
