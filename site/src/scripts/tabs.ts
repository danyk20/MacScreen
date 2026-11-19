/** Accessible tabs (WAI-ARIA tabs pattern with automatic activation). Without JavaScript all panels stay visible. */
document.querySelectorAll<HTMLElement>('[data-tabs]').forEach((root) => {
  const tabs = Array.from(root.querySelectorAll<HTMLButtonElement>('[role="tab"]'));
  const panels = tabs.map((t) => root.querySelector<HTMLElement>(`#${t.getAttribute('aria-controls')}`)!);
  root.classList.add('is-enhanced');

  const select = (index: number, focus = false): void => {
    tabs.forEach((tab, i) => {
      const on = i === index;
      tab.setAttribute('aria-selected', String(on));
      tab.tabIndex = on ? 0 : -1;
      panels[i]!.hidden = !on;
    });
    if (focus) tabs[index]!.focus();
  };

  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(i));
    tab.addEventListener('keydown', (e) => {
      const last = tabs.length - 1;
      const to = e.key === 'ArrowRight' ? (i === last ? 0 : i + 1)
        : e.key === 'ArrowLeft' ? (i === 0 ? last : i - 1)
        : e.key === 'Home' ? 0 : e.key === 'End' ? last : -1;
      if (to >= 0) { e.preventDefault(); select(to, true); }
    });
  });
  select(0);
});
