import assert from 'node:assert/strict';
import test from 'node:test';

import {
  compareVersions,
  createReleasePlan,
  extractChangelogSection,
  parseManifest,
  parseVersion,
  validateReleaseOrder,
} from './release-manifest.mjs';

const changelog = `# Changelog

## [Unreleased]

## [0.2.0-beta.1] - 2026-09-15

### Added

- Added release automation.

## [0.2.0-alpha.2] - 2026-09-14

### Fixed

- Fixed an earlier build.
`;

test('accepts stable, alpha, and beta release versions', () => {
  assert.equal(parseVersion('1.2.3').channel, 'stable');
  assert.equal(parseVersion('1.2.3-alpha.1').base, '1.2.3');
  assert.equal(parseVersion('1.2.3-beta.12').prerelease, true);
});

test('rejects unsupported release version forms', () => {
  for (const version of ['1.2', 'v1.2.3', '01.2.3', '1.2.3-alpha', '1.2.3-beta.0', 'dev-1.2.3']) {
    assert.throws(() => parseVersion(version));
  }
});

test('requires exactly the version, build, and packagingEnabled manifest fields', () => {
  const parsed = parseManifest('{"version":"1.2.3","build":4,"packagingEnabled":false}');
  assert.equal(parsed.packagingEnabled, false);
  assert.equal(parsed.build, 4);
  assert.throws(() => parseManifest('{"version":"1.2.3","packagingEnabled":false}'));
  assert.throws(() => parseManifest('{"version":"1.2.3","build":0,"packagingEnabled":false}'));
  assert.throws(() => parseManifest('{"version":"1.2.3","build":1,"packagingEnabled":"true"}'));
  assert.throws(() => parseManifest('{"version":"1.2.3","build":1,"packagingEnabled":true,"channel":"stable"}'));
});

test('extracts only the exact non-empty changelog section', () => {
  assert.equal(
    extractChangelogSection(changelog, '0.2.0-beta.1'),
    '### Added\n\n- Added release automation.',
  );
  assert.throws(() => extractChangelogSection(changelog, '0.2.0-beta.2'));
  assert.throws(() => extractChangelogSection('## [1.0.0] - 2026-02-30\n\n- Invalid date.', '1.0.0'));
  assert.throws(() => extractChangelogSection('## [1.0.0] - 2026-02-20\n\n## [1.1.0] - 2026-02-21', '1.0.0'));
  assert.throws(() => extractChangelogSection([
    '## [1.0.0] - 2026-02-20',
    '',
    '- First.',
    '',
    '## [1.0.0] - 2026-02-21',
    '',
    '- Duplicate.',
  ].join('\n'), '1.0.0'));
});

test('orders alpha, beta, stable, and subsequent base versions', () => {
  assert.equal(compareVersions('1.0.0-alpha.1', '1.0.0-alpha.2'), -1);
  assert.equal(compareVersions('1.0.0-alpha.2', '1.0.0-beta.1'), -1);
  assert.equal(compareVersions('1.0.0-beta.2', '1.0.0'), -1);
  assert.equal(compareVersions('1.0.0', '1.1.0-alpha.1'), -1);
});

test('rejects versions that do not advance published history', () => {
  assert.doesNotThrow(() => validateReleaseOrder(parseVersion('1.1.0-alpha.1'), ['v1.0.0']));
  assert.throws(() => validateReleaseOrder(parseVersion('1.0.0-beta.2'), ['v1.0.0']));
  assert.throws(() => validateReleaseOrder(parseVersion('1.0.0'), ['v1.0.0']));
});

test('does not require release notes while packaging is disabled', () => {
  const plan = createReleasePlan({
    manifestSource: '{"version":"0.2.0-beta.1","build":1,"packagingEnabled":false}',
    changelogSource: '',
    publishedTags: [],
  });
  assert.equal(plan.packagingEnabled, false);
});

test('requires matching notes and advancing history when packaging is enabled', () => {
  const plan = createReleasePlan({
    manifestSource: '{"version":"0.2.0-beta.1","build":2,"packagingEnabled":true}',
    changelogSource: changelog,
    publishedTags: ['v0.2.0-alpha.2'],
  });
  assert.equal(plan.packagingEnabled, true);
  assert.equal(plan.build, 2);
  assert.throws(() => createReleasePlan({
    manifestSource: '{"version":"0.2.0-beta.1","build":2,"packagingEnabled":true}',
    changelogSource: changelog,
    publishedTags: ['v0.2.0'],
  }));
});
