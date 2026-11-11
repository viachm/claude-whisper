# Translations of the landing page

The English page `../index.html` is the only source. `build.py` (Python 3, standard
library only) generates `<folder>/index.html` for every language that has a strings
file here. Never edit the generated pages by hand.

```
python3 i18n/build.py            # extract, check, render, write
python3 i18n/build.py --check    # write nothing; exit 1 if a file is stale or a language is broken
python3 i18n/build.py --lenient  # publish anyway: broken or missing strings fall back to English
```

Each run:

1. writes two generated blocks into `index.html`: `i18n:head` (hreflang links,
   `og:locale:alternate`, switcher CSS) and `i18n:switcher` (the language menu in
   the header). Don't edit them, and leave the markers in place;
2. extracts every visible string of `index.html` into `en.json`;
3. checks each `<code>.json` against `en.json` and stops with a list of errors
   (nothing is written apart from `en.json`) if one is wrong;
4. renders the pages and rewrites `../sitemap.xml` (the compare entries are kept).

A second run makes no changes.

## Files

- `languages.json`: every target language: BCP-47 `code`, URL `folder`, `name` as
  written in that language (shown in the menu), `og_locale`, `script` (picks the
  fonts, see `PROFILES` in `build.py`), optional `dir: "rtl"` and `quotes`.
- `en.json`: generated. Key → English string, in page order.
- `<code>.json` (e.g. `uk.json`, `pt-BR.json`, `zh-Hans.json`): one translation per
  language. Same keys as `en.json`, values translated.

## After the English page changes

Run `python3 i18n/build.py`. A key is `section.first-words.hash`, and the hash
comes from the English text, so a changed English string gets a new key. The
build reports it as "English changed" (with the new English and the old
translation) or "missing". Update each listed key in every `<code>.json` (rename
the key, translate the new text) and run again. Use `--lenient` only to deploy
before the translations are updated: those strings then show in English.

## Adding a language

1. Check that the language is in `languages.json` (all 30 targets are there).
2. Copy `en.json` to `<code>.json` (the code exactly as in `languages.json`).
3. Translate every value. Keep the keys and their order.
4. Run `python3 i18n/build.py` and fix what it reports. A file whose strings are
   mostly identical to English gets a warning.
5. Look at the page: serve the repository folder as `claude-whisper/` with
   `python3 -m http.server --bind 127.0.0.1` and open `/claude-whisper/<folder>/`.
   Check the header at about 360, 780 and 1280 px wide, since long words can push the menu out.

## Format of a value

Values are HTML fragments, copied into the page as written.

- Keep every tag exactly as in English: the same tags with the same attributes,
  as many times. You can move them and translate the text between them.
  The build fails if a tag goes missing, changes or appears out of nowhere.
- Text inside `<code>`, `<kbd>` and elements with `data-app` (the file names) stays
  as in English.
- Keep entities that are there (`&nbsp;`, `&amp;`). Don't add new tags.
- Keys under `head.`, and keys whose middle part starts with `alt-` or
  `aria-label-`, are plain text (titles, meta descriptions, image descriptions):
  no tags at all. Use typographic quotes there, not `"`.
- `head.title` must start with `Claude Whisper:` exactly. The page script
  replaces the text before the first colon with the app name.
- `switcher.label` is the word "Language" (menu label for screen readers).

## Translation rules

- Write natural, idiomatic marketing copy for a native speaker, not a literal
  translation. Keep the tone: short, plain, friendly.
- Never translate: Claude Whisper, Claude Code, Claude, Anthropic, GitHub, macOS,
  Windows, Apple, Developer ID, SmartScreen, Karabiner, file names, commands.
- Key names stay in English as the app shows them: Right Command, Right Option,
  Right Ctrl, Right Alt, Shift, Esc, ⌘ ⌥ ⇧. Words around them ("hold", "tap",
  "double-tap", "right") are translated.
- The app's own UI is English-only, so its labels stay in English: History,
  Settings, Settings › Pasting, Settings › General, Settings › Claude, Improve,
  Pasting, Sound and capsule, Faster start, Restart Session, Check for Updates,
  About, Paste and press Return, Open at login, the "Claude didn't start
  listening" message. You may add a translation in
  parentheses on the first mention, e.g. "Settings (налаштування)".
- Names in macOS or Windows themselves (Accessibility, Microphone, Applications,
  More info, Run anyway, Windows Settings paths) may use the name the OS shows in
  that language, with the English in parentheses, but only if you are sure of the
  exact name. Otherwise keep the English.
- Keep every fact identical: free, prices, version numbers (0.1.11), OS versions
  (macOS 14, Windows 10/11), limits (30 dictations, 10 s, about a second).
- Translate "unofficial, not made by, affiliated with or endorsed by Anthropic"
  faithfully and completely, in both the FAQ and the footer.
- Use the language's own punctuation and quotation marks.
- The example under "Improve" (`option 2, no, option 1`) and the typed sentence in
  the hero are translated too, as something a speaker of that language would say.
  Keep `fetchUser()` as is.
- Right-to-left languages (ar, he, fa): write the text normally. The page sets
  `dir="rtl"`, and the CSS keeps keycaps, code and shortcuts left-to-right.
