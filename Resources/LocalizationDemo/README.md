# Language pack demo / 语言包示例 / 言語パックのサンプル

Open Settings → Import Language Pack and choose `fr-demo.json`. The partial French demo switches immediately; missing entries use English. Select English, 日本語, 简体中文 or System Default to return. No restart is needed.

设置 → 导入语言包，选择 `fr-demo.json`。演示只翻译部分法语文字，其余回退英语。可随时切回内置语言。

設定 → 言語パックを読み込む → `fr-demo.json` を選択。翻訳のない項目は英語になります。再起動は不要です。

## Format

UTF-8 JSON fields: `schemaVersion: 1`, unique `id`, display `name`, BCP-47-style `locale`, and `strings` (key → translation). Copy the bundled `Languages/en.json` as a full template, change metadata, and translate only the values. Chinese source keys are stable identifiers; do not translate or rename them.

Use exactly the same numbered placeholders (`{0}`, `{1}`) as the source key. Their order may change. Values are plain text, never executable code, HTML, shell commands or printf formats. Filenames substituted into a placeholder are not interpreted as more placeholders.

Limits: 1 MB per file, 512 entries, 8000 characters per key/value, 80 characters for name. Unknown keys, malformed metadata, control characters and placeholder mismatches are rejected. Built-in IDs cannot be overwritten. Existing custom IDs require replacement confirmation.

Imported files are copied into `~/Library/Application Support/ArchiveDesk/LanguagePacks/`. Missing keys fall back to English. Remove a custom JSON file there and restart the app to remove it. Future releases may add keys; use the new English template when updating a pack. Older keys removed by a future schema may require a migration.

System-owned menus/file dialogs and raw CLI/OS error output may follow the macOS or tool language; all application-owned labels, actions and archive validation errors are translated. Technical language-pack validation errors currently use English so translators have a stable diagnostic.
