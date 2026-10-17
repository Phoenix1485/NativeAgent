const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const script = fs.readFileSync(path.join(__dirname, '../../Site/site.js'), 'utf8');
const prefix = 'https://github.com/Phoenix1485/NativeAgent/releases/';
async function render(release) {
  const elements = Object.fromEntries(['download', 'release', 'version', 'signing-title', 'signing-detail'].map(id => [id, {href: 'fallback', textContent: ''}]));
  elements.navDownload = {href: 'fallback'};
  elements.footerDownload = {href: 'fallback'};
  await vm.runInNewContext(script, {URL, fetch: async () => ({ok: true, json: async () => release}), document: {getElementById: id => elements[id], querySelectorAll: selector => {
    assert.equal(selector, '[data-download]');
    return [elements.download, elements.navDownload, elements.footerDownload];
  }}});
  return elements;
}
(async () => {
  const data = {version: '0.7.1', build: '15', format: 'dmg', notarized: true, download: prefix + 'download/v0.7.1-build.15/NativeAgent-15.dmg', updateDownload: prefix + 'download/v0.7.1-build.15/NativeAgent-15.zip', release: prefix + 'tag/v0.7.1-build.15'};
  const valid = await render(data);
  assert.equal(valid.download.href, data.download);
  assert.equal(valid.navDownload.href, data.download);
  assert.equal(valid.footerDownload.href, data.download);
  assert.equal(valid.version.textContent, 'Version 0.7.1 · Build 15');
  for (const change of [{download: data.updateDownload}, {format: 'zip'}, {download: 'https://attacker.invalid/install.dmg'}, {release: 'https://attacker.invalid/notes'}]) {
    const invalid = await render({...data, ...change});
    for (const link of [invalid.download, invalid.navDownload, invalid.footerDownload]) assert.equal(link.href, 'fallback');
  }
  console.log('PASS: website chooses the DMG, rejects ZIP and foreign-host links');
})().catch(error => { console.error(error); process.exitCode = 1; });
