/** Copy-to-clipboard buttons: <button data-copy="text">. Announces the result politely for screen readers. */
document.querySelectorAll<HTMLButtonElement>('[data-copy]').forEach((button) => {
  const label = button.querySelector<HTMLElement>('[data-copy-label]');
  const original = label?.textContent ?? 'Copy';
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy ?? '');
      if (label) label.textContent = 'Copied';
      button.classList.add('is-done');
    } catch {
      if (label) label.textContent = 'Press ⌘C';
    }
    setTimeout(() => { if (label) label.textContent = original; button.classList.remove('is-done'); }, 1800);
  });
});
