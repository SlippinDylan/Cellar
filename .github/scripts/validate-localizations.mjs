import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Extend this list as task pages replace the retained, unreachable provider UI.
export const presentationSources = [
  'CellarApp.swift',
  'Features/AppRootView.swift',
  'Features/AppCommands.swift',
  'Features/ShellPlaceholderView.swift',
  'Features/Home/HomeView.swift',
  'Features/Catalog/CatalogCardView.swift',
  'Features/Settings/SettingsView.swift',
  'Models/AppDestination.swift',
  'Models/ApplicationLanguage.swift',
];
export const requiredLanguages = ['en', 'zh-Hans', 'zh-Hant'];

const presentationLiteral = /\b(?:Text|Button|Label|Link|Tab|Picker|LabeledContent|ContentUnavailableView|CommandMenu|LocalizedStringResource|String\s*\(\s*localized:|help|alert|navigationTitle|navigationSubtitle|accessibilityLabel|accessibilityHint)\s*\(?\s*"((?:\\.|[^"\\])*)"/g;
const homePresentationLiteral = /\b(?:(?:countRow|inlineWarning)\s*\(|(?:HomeOnlineVersionRow|HomeTimestampRow)\s*\(\s*title:)\s*"((?:\\.|[^"\\])*)"/g;
const signature = value => value.match(/%(?:\d+\$)?(?:[-+0 #]*)(?:\d+|\*)?(?:\.\d+)?(?:hh|ll|[hlz])?[@diuoxXfFeEgGcCs]/g) ?? [];

export function validateLocalizations(catalog, sources) {
  const errors = [];
  if (catalog.sourceLanguage !== 'en') errors.push('Catalog sourceLanguage must be en');
  if (!catalog.strings || Object.keys(catalog.strings).length === 0) errors.push('Catalog must contain strings');
  for (const [key, entry] of Object.entries(catalog.strings ?? {})) {
    const values = [];
    for (const language of requiredLanguages) {
      const unit = entry.localizations?.[language]?.stringUnit;
      if (unit?.state !== 'translated' || typeof unit.value !== 'string' || !unit.value.trim()) {
        errors.push(`${key}: missing translated ${language}`);
      } else {
        values.push(unit.value);
      }
    }
    if (values.length === requiredLanguages.length && values.some(value => JSON.stringify(signature(value)) !== JSON.stringify(signature(values[0])))) {
      errors.push(`${key}: translation placeholders differ`);
    }
  }
  for (const [file, source] of Object.entries(sources)) {
    for (const match of [...source.matchAll(presentationLiteral), ...source.matchAll(homePresentationLiteral)]) {
      // SwiftUI's String interpolation uses %@ for these shell metadata values.
      const key = match[1].replace(/\\\([^)]*\)/g, '%@').replace(/\\n/g, '\n').replace(/\\"/g, '"');
      if (!catalog.strings?.[key]) errors.push(`${file}: uncatalogued presentation string ${JSON.stringify(key)}`);
    }
    if (/\bText\s*\(\s*verbatim:\s*"/.test(source)) errors.push(`${file}: presentation literal bypasses localization`);
    for (const declaration of source.matchAll(/\b(?:let|var)\s+(\w+)(?:\s*:\s*String)?\s*=\s*"/g)) {
      const use = new RegExp(`\\b(?:Text|Button|Label|Link)\\s*\\(\\s*${declaration[1]}\\s*[,)]`);
      if (use.test(source)) errors.push(`${file}: ${declaration[1]} presents a raw String literal; use LocalizedStringResource`);
    }
  }
  return errors;
}

export function validateRepository(root) {
  const catalog = JSON.parse(readFileSync(path.join(root, 'Resources/Localizable.xcstrings'), 'utf8'));
  const sources = Object.fromEntries(presentationSources.map(file => [file, readFileSync(path.join(root, file), 'utf8')]));
  return validateLocalizations(catalog, sources);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const errors = validateRepository(root);
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else {
    console.log(`Localization coverage passed: ${presentationSources.length} presentation files, ${requiredLanguages.join(', ')}`);
  }
}
