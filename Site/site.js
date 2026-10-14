'use strict';
// One request per page load; the release workflow publishes this metadata.
fetch('release.json', { cache: 'no-cache' })
  .then(response => { if (!response.ok) throw new Error('No release metadata'); return response.json(); })
  .then(release => {
    const download = new URL(release.download);
    const notes = new URL(release.release);
    if (download.origin !== 'https://github.com' || !download.pathname.startsWith('/Phoenix1485/NativeAgent/releases/download/')) return;
    if (notes.origin !== 'https://github.com' || !notes.pathname.startsWith('/Phoenix1485/NativeAgent/releases/tag/')) return;
    document.getElementById('download').href = download.href;
    document.getElementById('release').href = notes.href;
    document.getElementById('version').textContent = `Version ${release.version} · Build ${release.build}`;
    if (release.notarized === true) {
      document.getElementById('signing-title').textContent = 'Developer ID signed & Apple-notarized';
      document.getElementById('signing-detail').textContent = 'This release is signed with a Developer ID certificate and notarized by Apple. Sparkle also verifies the update archive and feed using NativeAgent’s Ed25519 key.';
    }
  })
  .catch(() => { /* Keep the working GitHub Releases links when metadata is unavailable. */ });
