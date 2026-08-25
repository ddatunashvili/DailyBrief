// Uploads a built installer to its GitHub release and writes the latest.yml
// electron-updater reads. electron-builder's own publish step keeps dying on
// a 72 MB upload (ECONNRESET) after it has already created the release, which
// leaves a tag with no assets and clients that see a 404 for latest.yml.
//
//   node scripts/publish-assets.js [version]
//
// Defaults to the version in package.json. Requires the gh CLI, authenticated.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const version = process.argv[2] || require(path.join(root, 'package.json')).version;
const outDir = path.join(root, 'output');
const exeName = `DailyBrief-Setup-${version}.exe`;
const exePath = path.join(outDir, exeName);
const ymlPath = path.join(outDir, 'latest.yml');
const tag = `v${version}`;
const repo = 'ddatunashvili/DailyBrief';

if (!fs.existsSync(exePath)) {
  console.error(`missing build: ${exePath}\nrun "npm run build" (or electron-builder --win nsis) first`);
  process.exit(1);
}

// electron-updater compares this against the file it downloads: sha512 of the
// bytes, base64 — not hex.
const buf = fs.readFileSync(exePath);
const sha512 = crypto.createHash('sha512').update(buf).digest('base64');
const yml = [
  `version: ${version}`,
  'files:',
  `  - url: ${exeName}`,
  `    sha512: ${sha512}`,
  `    size: ${buf.length}`,
  `path: ${exeName}`,
  `sha512: ${sha512}`,
  `releaseDate: '${new Date().toISOString()}'`,
  ''
].join('\n');
fs.writeFileSync(ymlPath, yml);
console.log(`latest.yml written for ${version} (${(buf.length / 1048576).toFixed(1)} MB)`);

function gh(args) {
  return execFileSync('gh', args, { cwd: outDir, stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
}

try {
  gh(['release', 'view', tag, '--repo', repo, '--json', 'tagName']);
  console.log(`release ${tag} exists`);
} catch (e) {
  gh(['release', 'create', tag, '--repo', repo, '--title', version, '--notes', `Release ${version}`]);
  console.log(`release ${tag} created`);
}

// The installer goes up first and the manifest last: a latest.yml pointing at
// an asset that is not there yet is exactly the 404 this script exists to fix.
for (const file of [exeName, 'latest.yml']) {
  let lastErr = null;
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      gh(['release', 'upload', tag, file, '--repo', repo, '--clobber']);
      console.log(`uploaded ${file}`);
      lastErr = null;
      break;
    } catch (e) {
      lastErr = e;
      console.log(`upload of ${file} failed (attempt ${attempt}/5): ${String(e.stderr || e.message).trim()}`);
    }
  }
  if (lastErr) {
    console.error(`giving up on ${file}`);
    process.exit(1);
  }
}

console.log(`done: https://github.com/${repo}/releases/tag/${tag}`);
