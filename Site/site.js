'use strict';
// One request per page load; the release workflow publishes this metadata.
fetch('release.json', { cache: 'no-cache' })
  .then(response => { if (!response.ok) throw new Error('No release metadata'); return response.json(); })
  .then(release => {
    const download = new URL(release.download);
    const notes = new URL(release.release);
    if (release.format !== 'dmg' || download.origin !== 'https://github.com' || !download.pathname.startsWith('/Phoenix1485/NativeAgent/releases/download/') || !download.pathname.endsWith('.dmg')) return;
    if (notes.origin !== 'https://github.com' || !notes.pathname.startsWith('/Phoenix1485/NativeAgent/releases/tag/')) return;
    document.getElementById('download').href = download.href;
    document.getElementById('release').href = notes.href;
    document.getElementById('version').textContent = `Version ${release.version} · Build ${release.build}`;
    if (release.notarized === true) {
      document.getElementById('signing-title').textContent = 'Developer ID signed & Apple-notarized';
      document.getElementById('signing-detail').textContent = 'The app and DMG installer are Developer ID signed and Apple-notarized. Automatic updates separately use an Ed25519-verified archive and feed.';
    }
  })
  .catch(() => { /* Keep the working GitHub Releases links when metadata is unavailable. */ });
