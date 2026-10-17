'use strict';
// Progressive enhancement: the chat preview and download links also work without JS.
const previewTabs = document.querySelector('.preview-tabs');
if (previewTabs) {
  const tabs = Array.from(previewTabs.querySelectorAll('[role="tab"]'));
  const activate = (selected, focus = false) => {
    const changed = selected.getAttribute('aria-selected') !== 'true';
    for (const tab of tabs) {
      const active = tab === selected;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute('aria-controls'));
      panel.hidden = !active;
      panel.setAttribute('role', 'tabpanel');
      panel.setAttribute('aria-labelledby', tab.id);
      panel.tabIndex = 0;
    }
    if (focus) selected.focus();
    if (changed) document.dispatchEvent(new CustomEvent('nativeagent:preview', {
      detail: { panel: document.getElementById(selected.getAttribute('aria-controls')) }
    }));
  };
  for (const [index, tab] of tabs.entries()) {
    tab.addEventListener('click', () => activate(tab));
    tab.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next !== undefined) {
        event.preventDefault();
        activate(tabs[next], true);
      }
    });
  }
  activate(tabs[0]);
  previewTabs.hidden = false;
}

// A link to connection details should reveal the answer as well as scroll to it.
const revealLinkedDetails = () => {
  const target = document.getElementById(window.location.hash.slice(1));
  if (target instanceof HTMLDetailsElement) target.open = true;
};
window.addEventListener('hashchange', revealLinkedDetails);
document.addEventListener('click', event => {
  const link = event.target.closest('a[href^="#"]');
  const target = link && document.getElementById(link.getAttribute('href').slice(1));
  if (target instanceof HTMLDetailsElement) target.open = true;
});
revealLinkedDetails();
