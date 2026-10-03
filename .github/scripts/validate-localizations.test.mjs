import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validateLocalizations, validateRepository, requiredLanguages } from './validate-localizations.mjs';

const entry = value => ({ localizations: Object.fromEntries(requiredLanguages.map(language => [language, {
  stringUnit: { state: 'translated', value },
}])) });
const catalog = () => ({ sourceLanguage: 'en', strings: { Home: entry('Home'), 'Version %@': entry('Version %@') } });

test('reachable Cellar presentation has complete catalog coverage', () => {
  assert.deepEqual(validateRepository(fileURLToPath(new URL('../../', import.meta.url))), []);
});

test('missing language and untranslated language both fail', () => {
  for (const language of requiredLanguages) {
    const missing = catalog();
    delete missing.strings.Home.localizations[language];
    assert.match(validateLocalizations(missing, {})[0], new RegExp(language));
    const untranslated = catalog();
    untranslated.strings.Home.localizations[language].stringUnit.state = 'new';
    assert.ok(validateLocalizations(untranslated, {}).length);
  }
});

test('new unlocalized literals in views, menus, help and resources fail', () => {
  for (const source of ['Text("Missing")', 'Button("Missing") {}', 'Link("Missing", destination: url)', '.help("Missing")', 'LocalizedStringResource("Missing")', 'CommandMenu("Missing") {}', 'countRow("Missing", count)', 'inlineWarning("Missing")', 'HomeOnlineVersionRow(title: "Missing", state: state)', 'HomeTimestampRow(title: "Missing", date: date)']) {
    assert.match(validateLocalizations(catalog(), { 'View.swift': source })[0], /uncatalogued presentation string/);
  }
  assert.match(validateLocalizations(catalog(), { 'View.swift': 'Text(verbatim: "Home")' })[0], /bypasses localization/);
  assert.match(validateLocalizations(catalog(), { 'View.swift': 'let title = "Home"; Text(title)' })[0], /raw String literal/);
});

test('catalogued interpolation passes and mismatched placeholders fail', () => {
  assert.deepEqual(validateLocalizations(catalog(), { 'View.swift': 'Text("Version \\(version)")' }), []);
  const invalid = catalog();
  invalid.strings['Version %@'].localizations['zh-Hant'].stringUnit.value = '版本';
  assert.match(validateLocalizations(invalid, {})[0], /placeholders differ/);
});
