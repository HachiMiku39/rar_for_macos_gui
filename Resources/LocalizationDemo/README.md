# English-first language packs

English is ArchiveDesk's source language and fallback language. New installations default to English; existing language choices are preserved. System Default remains available in Settings.

## Start translating

1. Copy `en-template.json` to a writable folder. It contains every current English source string.
2. Change `id` (for example `fr-custom`), `name` (for example `Français`) and `locale` (for example `fr`). Do not use the built-in IDs `en`, `ja` or `zh-Hans`.
3. Translate only the **values** inside `strings`. Keep the English keys unchanged. You may remove untranslated entries; they fall back to English.
4. In ArchiveDesk 0.5.1 or later, open Settings → Import Language Pack and select your JSON file. The language switches immediately, without restarting.

`fr-demo.json` is a small English → French example, not a complete French translation. It intentionally leaves other entries in English. Select English, 日本語, 简体中文 or System Default to switch back.

## Schema v2

```json
{
  "schemaVersion": 2,
  "sourceLanguage": "en",
  "id": "fr-custom",
  "name": "Français",
  "locale": "fr",
  "strings": {
    "Open": "Ouvrir",
    "Cancel": "Annuler",
    "{0} items": "{0} éléments"
  }
}
```

Use UTF-8 JSON. `sourceLanguage` must be `en`; `locale` identifies the target language. No Chinese knowledge is required. English keys are exact, case-sensitive identifiers: preserve spaces, punctuation and numbered placeholders (`{0}`, `{1}`). Placeholder order may change, but each placeholder must appear the same number of times.

Values are plain text, never executable code, HTML, shell commands or printf formats. Filenames substituted into placeholders are not interpreted as further placeholders. Limits: 1 MB per file, 512 entries, 8000 characters per key/value, 80 characters for name. Unknown keys, malformed metadata, control characters and placeholder mismatches are rejected. Existing custom IDs require confirmation before replacement.

## Compatibility and storage

ArchiveDesk 0.5.1+ reads old schema v1 packs using its bundled legacy-key map. Previously imported packs are converted in memory without modifying their files. Importing a v1 pack saves a normalized v2 copy. The legacy map is internal compatibility data, not a translation template. Schema v2 packs require ArchiveDesk 0.5.1+; version 0.5.0 and earlier cannot import them.

Imported packs are stored in `~/Library/Application Support/ArchiveDesk/LanguagePacks/`. Remove a custom file there and restart to remove that pack. New app versions may add keys; compare against the latest English template when updating translations. Existing v2 keys should remain stable; changing a key requires explicit migration.

System-owned menus/dialogs and raw CLI/OS errors may use the system or tool language. Application-owned text and validation messages use the selected language; missing translations fall back to English. Technical pack-validation diagnostics are English.

简体中文：复制完整英文模板，只翻译右侧值，左侧英文原文保持不变。法语 Demo 仅作示例，缺失项回退英语。新版仍兼容旧中文键语言包。

日本語：完全な英語テンプレートをコピーし、右側の値だけを翻訳してください。英語キーは変更しません。未翻訳の項目は英語に戻ります。旧形式の言語パックも読み込めます。
