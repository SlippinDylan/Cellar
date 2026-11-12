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
  for (const source of ['Text("Missing")', 'Button("Missing") {}', 'Link("Missing", destination: url)', '.help("Missing")', 'LocalizedStringResource("Missing")', 'CommandMenu("Missing") {}', 'countRow("Missing", count)', 'inlineWarning("Missing")', 'pathRow("Missing", path)', 'pathList("Missing", paths)', 'receiptSection("Missing") {}', 'HomeOnlineVersionRow(title: "Missing", state: state)', 'HomeTimestampRow(title: "Missing", date: date)']) {
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


test('integer, string and mixed Swift interpolation use catalog format types', () => {
  const typed = catalog();
  typed.strings['%lld Selected Plugins'] = entry('%lld Selected Plugins');
  typed.strings['%1$lld plugins for %2$@ (100%%)'] = entry('%1$lld plugins for %2$@ (100%%)');
  assert.deepEqual(validateLocalizations(typed, {
    'View.swift': 'Text("\\(plugins.count) Selected Plugins"); Text("\\(plugins.count) plugins for \\(name) (100%)")',
  }), []);
  assert.match(validateLocalizations(typed, {
    'View.swift': 'Text("\\(plugins.count) Selected Missing Plugins")',
  })[0], /uncatalogued presentation string/);
  assert.match(validateLocalizations(typed, {
    'View.swift': 'Text("\\(plugins.count) Selected Plugins \\(name)")',
  })[0], /uncatalogued presentation string/);
  typed.strings['%lld Selected Plugins'].localizations['zh-Hans'].stringUnit.value = '%@ Selected Plugins';
  assert.match(validateLocalizations(typed, {})[0], /placeholders differ/);
});

test('ambiguous interpolation shapes fail instead of guessing Swift types', () => {
  const ambiguous = catalog();
  ambiguous.strings['Version %lld'] = entry('Version %lld');
  assert.match(validateLocalizations(ambiguous, { 'View.swift': 'Text("Version \\(version)")' })[0], /ambiguous presentation string/);
  assert.deepEqual(validateLocalizations(ambiguous, { 'View.swift': 'Text("Version %@")' }), []);
});

test('escaped percent signs are literal and format types still match', () => {
  const percent = { sourceLanguage: 'en', strings: { 'Literal %%@: %@': entry('Literal %%@: %@') } };
  percent.strings['Literal %%@: %@'].localizations['zh-Hans'].stringUnit.value = '文字 %%d：%@';
  assert.deepEqual(validateLocalizations(percent, {}), []);
});
