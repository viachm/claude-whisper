#!/usr/bin/env python3
"""Generate the translated landing pages from the English index.html.

    python3 i18n/build.py            extract, validate, render and write
    python3 i18n/build.py --check    the same, but write nothing; exit 1 if a
                                     file is out of date or a language is broken
    python3 i18n/build.py --lenient  missing or broken strings fall back to
                                     English (warnings instead of errors)

Source of truth: ../index.html (English). Every run
  1. writes the generated blocks (hreflang links, language switcher) into it,
  2. extracts its user-visible strings into i18n/en.json,
  3. checks each i18n/<code>.json against en.json,
  4. renders <folder>/index.html for each language and rewrites sitemap.xml.
Running it twice gives no diff. Standard library only. See i18n/README.md.
"""
import argparse
import datetime
import hashlib
import html
import json
import re
import sys
import unicodedata
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SOURCE = ROOT / "index.html"
SITEMAP = ROOT / "sitemap.xml"
LANGS_FILE = HERE / "languages.json"
EN_FILE = HERE / "en.json"

# Names that stay in English in every language; the check warns when one goes missing.
PROTECTED = ["Claude Whisper", "Claude Code", "Anthropic", "GitHub", "macOS", "Windows"]

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "source", "track", "wbr"}
# Elements that can sit inside a sentence; they travel with the text as markup.
INLINE = {"a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "data", "del", "dfn", "em",
          "i", "ins", "kbd", "mark", "q", "s", "samp", "small", "span", "strong", "sub",
          "sup", "time", "u", "var", "wbr"}
OPAQUE = {"script", "style", "svg", "template", "noscript", "textarea"}
ATTRS = ["alt", "aria-label", "title", "placeholder"]
META = {"description", "og:title", "og:description", "og:image:alt",
        "twitter:title", "twitter:description", "twitter:image:alt"}

# Synthetic strings: text the build itself adds to every page.
SYNTHETIC = {"switcher.label": "Language"}

# Fonts per script. Figtree (Google Fonts) only has Latin, so other scripts use
# system fonts that cover them, with letter-spacing and line-height made safe.
SYSTEM = 'system-ui, -apple-system, "Segoe UI", Roboto'
PROFILES = {
    "latin": None,
    "vietnamese": {"sans": SYSTEM + ', "Noto Sans", Arial, sans-serif'},
    "cyrillic": {"sans": SYSTEM + ', "Noto Sans", "Helvetica Neue", Arial, sans-serif'},
    "greek": {"sans": SYSTEM + ', "Noto Sans", "Helvetica Neue", Arial, sans-serif'},
    "arabic": {"sans": SYSTEM + ', "Geeza Pro", Tahoma, "Noto Sans Arabic", sans-serif', "complex": 1.35},
    "hebrew": {"sans": SYSTEM + ', "Arial Hebrew", Arial, "Noto Sans Hebrew", sans-serif', "complex": 1.3},
    "devanagari": {"sans": SYSTEM + ', "Kohinoor Devanagari", "Nirmala UI", "Noto Sans Devanagari", sans-serif', "complex": 1.4},
    "bengali": {"sans": SYSTEM + ', "Kohinoor Bangla", "Nirmala UI", "Noto Sans Bengali", sans-serif', "complex": 1.4},
    "thai": {"sans": SYSTEM + ', Thonburi, "Leelawadee UI", "Noto Sans Thai", sans-serif', "complex": 1.45},
    "ja": {"sans": SYSTEM + ', "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic UI", Meiryo, "Noto Sans JP", sans-serif', "complex": 1.3},
    "ko": {"sans": SYSTEM + ', "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans KR", sans-serif', "complex": 1.3},
    "zh-hans": {"sans": SYSTEM + ', "PingFang SC", "Microsoft YaHei", "Noto Sans SC", sans-serif', "complex": 1.3},
    "zh-hant": {"sans": SYSTEM + ', "PingFang TC", "Microsoft JhengHei", "Noto Sans TC", sans-serif', "complex": 1.3},
}

SWITCHER_CSS = """\
.vh { position: absolute !important; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
.lang { position: relative; flex: none; font-size: 15px; font-weight: 500; }
.lang summary { list-style: none; display: inline-flex; align-items: center; gap: 6px; height: 34px; padding: 0 10px; border: 1px solid var(--line-strong); border-radius: 9px; color: var(--ink); cursor: pointer; white-space: nowrap; }
.lang summary::-webkit-details-marker { display: none; }
.lang summary:hover, .lang[open] summary { border-color: var(--accent); }
.lang summary svg { width: 16px; height: 16px; flex: none; }
.lang ul { position: absolute; top: calc(100% + 8px); inset-inline-end: 0; z-index: 20; margin: 0; padding: 6px; list-style: none; display: grid; grid-template-columns: repeat(COLS, minmax(0, 1fr)); gap: 2px; width: max-content; max-width: calc(100vw - 32px); max-height: min(70vh, 560px); overflow: auto; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; box-shadow: var(--shadow); }
.lang li a { display: block; padding: 7px 12px; text-align: start; border-radius: 8px; color: var(--ink-2); text-decoration: none; white-space: nowrap; }
.lang li a:hover { background: var(--bg-alt); color: var(--ink); }
.lang li a[aria-current] { background: var(--accent-soft); color: var(--ink); font-weight: 600; }
.nav a { white-space: nowrap; }
@media (max-width: 1000px) {
  .nav { gap: 16px; }
  .lang summary { padding: 0 9px; }
  .lang .lang-name { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
}
@media (max-width: 520px) { .top .wrap { gap: 14px; } }"""

RTL_CSS = """\
[dir="rtl"] .nav { margin-left: 0; margin-right: auto; }
[dir="rtl"] .hero { background: radial-gradient(70% 60% at 15% 10%, var(--accent-soft), transparent 70%); }
[dir="rtl"] .faq summary { padding: 20px 0 20px 40px; }
[dir="rtl"] .faq summary::after { right: auto; left: 6px; }
[dir="rtl"] .key, [dir="rtl"] .window-bar { direction: ltr; }
[dir="rtl"] .krow .keys { direction: ltr; justify-content: flex-end; }
[dir="rtl"] .krow .keys .or { direction: rtl; }
[dir="rtl"] code, [dir="rtl"] kbd { direction: ltr; unicode-bidi: isolate; }"""

GLOBE = ('<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" '
         'stroke-width="1.8" stroke-linecap="round" d="M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm-9-9h18M12 3c2.5 2.4 3.8 5.4 3.8 9s-1.3 6.6-3.8 9c-2.5-2.4-3.8-5.4-3.8-9S9.5 5.4 12 3Z"/></svg>')

SWITCHER_JS = """<script>
(() => {
  const d = document.currentScript.previousElementSibling;
  document.addEventListener("click", e => { if (d.open && !d.contains(e.target)) d.open = false; });
  document.addEventListener("keydown", e => { if (e.key === "Escape" && d.open) { d.open = false; d.querySelector("summary").focus(); } });
})();
</script>"""

BLOCK_RE = {name: re.compile(r"<!-- i18n:%s\b.*?-->.*?<!-- /i18n:%s -->" % (name, name), re.S)
            for name in ("head", "switcher")}


class Fail(Exception):
    pass


# ---------------------------------------------------------------- parsing

class Node:
    def __init__(self, tag, attrs, start, open_end, parent):
        self.tag, self.attrs, self.start, self.open_end = tag, attrs, start, open_end
        self.close_start = self.end = open_end
        self.children, self.parent = [], parent


class Text:
    def __init__(self, start, end):
        self.start, self.end = start, end


class Tree(HTMLParser):
    """A minimal DOM that remembers where every tag and text run sits in the source."""
    ENTITY = re.compile(r"&#?[0-9A-Za-z]+;?")

    def __init__(self, src):
        super().__init__(convert_charrefs=False)
        self.src = src
        self.lines = [0] + [m.end() for m in re.finditer("\n", src)]
        self.root = Node("#root", {}, 0, 0, None)
        self.stack = [self.root]
        self.feed(src)
        self.close()
        for n in self.stack[1:]:
            n.close_start = n.end = len(src)

    def _pos(self):
        line, col = self.getpos()
        return self.lines[line - 1] + col

    def _add(self, tag, attrs, void):
        s = self._pos()
        n = Node(tag, dict(attrs), s, s + len(self.get_starttag_text()), self.stack[-1])
        self.stack[-1].children.append(n)
        if not void:
            self.stack.append(n)

    def handle_starttag(self, tag, attrs):
        self._add(tag, attrs, tag in VOID)

    def handle_startendtag(self, tag, attrs):
        self._add(tag, attrs, True)

    def handle_endtag(self, tag):
        s = self._pos()
        e = self.src.index(">", s) + 1
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                for n in self.stack[i + 1:]:      # implicitly closed
                    n.close_start = n.end = s
                self.stack[i].close_start, self.stack[i].end = s, e
                del self.stack[i:]
                return

    def handle_data(self, data):
        s = self._pos()
        self.stack[-1].children.append(Text(s, s + len(data)))

    def handle_entityref(self, name):
        s = self._pos()
        self.stack[-1].children.append(Text(s, self.ENTITY.match(self.src, s).end()))

    handle_charref = handle_entityref

    def handle_comment(self, data):
        s = self._pos()
        self.stack[-1].children.append(Node("#comment", {}, s, s + len(data) + 7, self.stack[-1]))


def walk(node):
    yield node
    for c in node.children:
        if isinstance(c, Node):
            yield from walk(c)


def attr_span(src, node, name):
    """(start, end) of the attribute value in the source, or None."""
    tag = src[node.start:node.open_end]
    m = re.search(r'\s%s\s*=\s*(?:"([^"]*)"|\'([^\']*)\')' % re.escape(name), tag)
    if not m:
        return None
    g = 1 if m.group(1) is not None else 2
    return node.start + m.start(g), node.start + m.end(g)


def find(tree, tag, **want):
    for n in walk(tree.root):
        if n.tag == tag and all(n.attrs.get(k.replace("_", "-")) == v for k, v in want.items()):
            return n
    return None


# ---------------------------------------------------------------- extraction

def norm(s):
    return " ".join(s.split())


def plain(s):
    return html.unescape(re.sub(r"<[^>]*>", "", s))


def slug(text, words=5):
    t = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return "-".join(re.findall(r"[a-z0-9]+", t)[:words]) or "x"


def section_of(node, current):
    if node.tag in ("head", "header", "footer"):
        return node.tag
    if node.tag == "section":
        return node.attrs.get("id") or re.sub(r"-title$", "", node.attrs.get("aria-labelledby", "")) or current
    return current


class Page:
    """The English source, parsed: its segments and the nodes the renderer rewrites."""

    def __init__(self, src):
        self.src = src
        self.tree = Tree(src)
        self.blocks = [m.span() for name in BLOCK_RE for m in BLOCK_RE[name].finditer(src)]
        self.segs = []          # (start, end, key, kind); kind: html | attr | title
        self.en = {}            # key -> English value (whitespace collapsed)
        self.kinds = {}
        self.jsonld = None
        self.problems = []
        self._visit(self.tree.root, "page")
        self.segs.sort()
        for (a, b, *_), (c, *_r) in zip(self.segs, self.segs[1:]):
            if c < b:
                raise Fail(f"overlapping segments at offset {c}")
        for key, value in SYNTHETIC.items():
            self.en[key], self.kinds[key] = value, "attr"

    def _blocked(self, pos):
        return any(a <= pos < b for a, b in self.blocks)

    def _add(self, a, b, section, kind, hint=None):
        src = self.src
        while a < b and src[a].isspace():
            a += 1
        while b > a and src[b - 1].isspace():
            b -= 1
        value = norm(src[a:b])
        if not any(ch.isalpha() for ch in plain(value)):
            return
        name = hint or slug(plain(value))
        key = f"{section}.{name}.{hashlib.sha1(value.encode()).hexdigest()[:6]}"
        self.en[key], self.kinds[key] = value, kind
        self.segs.append((a, b, key, kind))

    def _skipped(self, n):
        return (n.tag in OPAQUE or n.tag == "kbd" or "data-app" in n.attrs
                or n.attrs.get("translate") == "no")

    def _visit(self, n, section):
        if self._blocked(n.start):
            return
        section = section_of(n, section)
        if n.tag == "script" and n.attrs.get("type") == "application/ld+json":
            self._jsonld(n)
        if self._skipped(n) or n.tag == "#comment":
            return
        for name in ATTRS:
            span = attr_span(self.src, n, name)
            if span:
                v = self.src[span[0]:span[1]]
                self._add(*span, section, "attr", f"{name}-{slug(plain(v), 4)}")
        meta = n.attrs.get("name") or n.attrs.get("property")
        if n.tag == "meta" and meta in META:
            span = attr_span(self.src, n, "content")
            self._add(*span, section, "attr", meta.replace(":", "-"))
        if n.tag == "title":
            self._add(n.open_end, n.close_start, section, "title", "title")
            return
        self._children(n.children, section)

    def _children(self, children, section):
        run = []

        def flush():
            if not run:
                return
            if any(isinstance(c, Text) and self.src[c.start:c.end].strip() for c in run):
                if not self._blocked(run[0].start):
                    self._add(run[0].start, run[-1].end, section, "html")
            else:
                for c in run:
                    if isinstance(c, Node):
                        self._visit(c, section)
            run.clear()

        for c in children:
            if isinstance(c, Text) or c.tag in INLINE:
                run.append(c)
            else:
                flush()
                self._visit(c, section)
        flush()

    def _jsonld(self, n):
        text = self.src[n.open_end:n.close_start]
        try:
            data = json.loads(text)
        except ValueError as e:
            raise Fail(f"index.html: JSON-LD does not parse: {e}")
        self.jsonld = (n, data)
        for node in json_nodes(data):
            if "inLanguage" in node and isinstance(node.get("description"), str):
                value = norm(html.escape(node["description"], quote=False))
                key = f"head.jsonld-description.{hashlib.sha1(value.encode()).hexdigest()[:6]}"
                self.en[key], self.kinds[key] = value, "json"


def json_nodes(data):
    if isinstance(data, dict):
        yield data
        for v in data.values():
            yield from json_nodes(v)
    elif isinstance(data, list):
        for v in data:
            yield from json_nodes(v)


# ---------------------------------------------------------------- checks

TAG = re.compile(r"<[^>]+>")
VERBATIM = re.compile(r"<(code|kbd)\b[^>]*>(.*?)</\1>|<(\w+)\b[^>]*\b(?:data-app|translate)=[^>]*>(.*?)</\3>", re.S)


def tags(s):
    return Counter(norm(t) for t in TAG.findall(s))


def verbatim(s):
    return Counter(m.group(0) if m.group(1) is None else m.group(2) for m in VERBATIM.finditer(s))


def check(lang, strings, page):
    """Return (errors, warnings, bad_keys) for one language's strings."""
    errors, warnings, bad = [], [], set()
    en = page.en
    missing = [k for k in en if k not in strings]
    extra = [k for k in strings if k not in en]
    # A changed English string gets a new key: pair it with the stale key that has the
    # same stem, or that sits in the same place (same key before it) in the strings file.
    en_keys, lang_keys = list(en), list(strings)
    before = lambda seq, k: seq[seq.index(k) - 1] if seq.index(k) else None
    stem = lambda k: k.rsplit(".", 1)[0]
    pairs = {}
    for k in missing:
        for x in extra:
            if x not in pairs.values() and (stem(x) == stem(k) or (
                    x.split(".")[0] == k.split(".")[0] and before(lang_keys, x) == before(en_keys, k))):
                pairs[k] = x
                break
    for k in missing:
        if k in pairs:
            errors.append(f"{k}: English changed, update the translation and its key. "
                          f"English now: {en[k]!r}; old key {pairs[k]} has: {strings[pairs[k]]!r}")
        else:
            errors.append(f"{k}: missing. English: {en[k]!r}")
    for k in extra:
        if k not in pairs.values():
            errors.append(f"{k}: not in en.json (remove it)")
    for k, v in strings.items():
        if k not in en:
            continue
        e = en[k]
        if not isinstance(v, str) or not v.strip():
            errors.append(f"{k}: empty or not a string")
            bad.add(k)
            continue
        if tags(v) != tags(e):
            lost, added = tags(e) - tags(v), tags(v) - tags(e)
            errors.append(f"{k}: markup differs from English"
                          + (f"; missing {sorted(lost)}" if lost else "")
                          + (f"; unexpected {sorted(added)}" if added else ""))
            bad.add(k)
        elif verbatim(v) != verbatim(e):
            errors.append(f"{k}: text inside <code>/<kbd>/data-app must stay as in English: "
                          f"{sorted(verbatim(e).elements())}")
            bad.add(k)
        if page.kinds[k] == "title":
            if v.split(":", 1)[0] != e.split(":", 1)[0] or ":" not in v:
                errors.append(f"{k}: the title must start with {e.split(':', 1)[0] + ':'!r} "
                              "(the page script relies on it)")
                bad.add(k)
        if '"' in v and page.kinds[k] in ("attr", "json") and '"' not in e:
            warnings.append(f"{k}: contains a straight double quote; prefer typographic quotes")
        for name in PROTECTED:
            if name in plain(e) and name not in plain(v):
                warnings.append(f"{k}: {name!r} is in English but not in the translation")
    for k in missing:
        bad.add(k)
    same = [k for k in en if k in strings and norm(strings[k]) == en[k]]
    if len(same) > len(en) // 3:
        warnings.append(f"{len(same)} of {len(en)} strings are identical to English; untranslated?")
    return errors, warnings, bad


# ---------------------------------------------------------------- rendering

def esc_attr(v):
    return v.replace('"', "&quot;")


def base_url(page):
    n = find(page.tree, "link", rel="canonical")
    if not n:
        raise Fail("index.html has no <link rel=\"canonical\">")
    url = n.attrs["href"]
    return url if url.endswith("/") else url + "/"


def page_url(base, lang):
    return base + (lang["folder"] + "/" if lang["folder"] else "")


def head_block(page, lang, langs, built):
    base = base_url(page)
    out = ["<!-- i18n:head (generated by i18n/build.py from i18n/languages.json; edits here are overwritten) -->"]
    for l in built:
        out.append(f'<link rel="alternate" hreflang="{l["code"]}" href="{page_url(base, l)}">')
    out.append(f'<link rel="alternate" hreflang="x-default" href="{base}">')
    for l in built:
        if l is not lang:
            out.append(f'<meta property="og:locale:alternate" content="{l["og_locale"]}">')
    css = [SWITCHER_CSS.replace("COLS", "1" if len(built) <= 10 else "2")]
    prof = PROFILES[lang["script"]]
    if prof:
        css.append(f':root {{ --sans: {prof["sans"]}; }}')
        if "complex" in prof:
            lh = prof["complex"]
            css.append("*, *::before, *::after { letter-spacing: 0 !important; }")
            css.append(f"h1, h2, h3 {{ line-height: {lh}; }} .hero h1 {{ line-height: {lh - .1:.2f}; }}")
            css.append(".kicker, .tag, .krow .or, .ba .lab, .key-row > span, .codebar { font-family: var(--sans); }")
        # Keep headings from breaking mid-word: Japanese by phrase (Chrome/Edge),
        # Korean between words, as Korean typesetting expects everywhere.
        if lang["script"] == "ja":
            css.append("h1, h2, h3 { word-break: auto-phrase; }")
        if lang["script"] == "ko":
            css.append("body { word-break: keep-all; overflow-wrap: anywhere; }")
    if lang.get("quotes"):
        o, c = lang["quotes"]
        css.append(f'.ba q {{ quotes: "{o}" "{c}"; }}')
    if lang.get("dir") == "rtl":
        css.append(RTL_CSS)
    out.append("<style>\n" + "\n".join(css) + "\n</style>")
    out.append("<!-- /i18n:head -->")
    return "\n".join(out)


def switcher_block(page, lang, built, strings):
    label = strings.get("switcher.label") or SYNTHETIC["switcher.label"]
    items = []
    for l in built:
        href = l["folder"] + "/" if l["folder"] else "./"
        attrs = f' lang="{l["code"]}" hreflang="{l["code"]}" dir="{l.get("dir", "ltr")}"'
        if l is lang:
            attrs += ' aria-current="page"'
        items.append(f'        <li><a href="{href}"{attrs}>{l["name"]}</a></li>')
    return "\n".join([
        "<!-- i18n:switcher (generated by i18n/build.py; edits here are overwritten) -->",
        '    <details class="lang" translate="no">',
        f'      <summary>{GLOBE}<span class="vh">{html.escape(label)}: </span><span class="lang-name">{lang["name"]}</span></summary>',
        f'      <ul aria-label="{esc_attr(label)}">',
        *items,
        "      </ul>",
        "    </details>",
        "    " + SWITCHER_JS.replace("\n", "\n    "),
        "    <!-- /i18n:switcher -->",
    ])


def splice_blocks(src, head, switcher):
    """Put the two generated blocks into the source, replacing old ones or adding them."""
    for name, block, anchor, before in (("head", head, "</head>", True), ("switcher", switcher, "</nav>", False)):
        if BLOCK_RE[name].search(src):
            src = BLOCK_RE[name].sub(lambda _: block, src, count=1)
        else:
            i = src.find(anchor)
            if i < 0:
                raise Fail(f"index.html: no {anchor} to put the {name} block next to")
            src = src[:i] + block + "\n" + src[i:] if before else \
                src[:i + len(anchor)] + "\n    " + block + src[i + len(anchor):]
    return src


def rewrite_relative(out):
    """Point relative src/href one folder up (outside <script> and <style>)."""
    def fix(m):
        v = m.group(2)
        if re.match(r"(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//|#|/|\.\./)", v):
            return m.group(0)
        v = v[2:] if v.startswith("./") else v
        return f'{m.group(1)}"../{v}"'
    parts = re.split(r"(<script\b.*?</script>|<style\b.*?</style>)", out, flags=re.S)
    for i in range(0, len(parts), 2):
        parts[i] = re.sub(r'(\s(?:src|href)=)"([^"]*)"', fix, parts[i])
    return "".join(parts)


def render(page, lang, langs, built, strings):
    src = page.src
    base = base_url(page)
    url = page_url(base, lang)
    is_en = lang["code"] == "en"
    reps = []
    for a, b, key, kind in page.segs:
        v = strings.get(key)
        if v is None or norm(v) == page.en[key]:
            continue
        reps.append((a, b, esc_attr(v) if kind == "attr" else v))
    for name, block in (("head", head_block(page, lang, langs, built)),
                        ("switcher", switcher_block(page, lang, built, strings))):
        m = BLOCK_RE[name].search(src)
        reps.append((m.start(), m.end(), block))
    if not is_en:
        h = find(page.tree, "html")
        span = attr_span(src, h, "lang")
        reps.append((*span, lang["code"] + ('" dir="rtl' if lang.get("dir") == "rtl" else "")))
        reps.append((*attr_span(src, find(page.tree, "link", rel="canonical"), "href"), url))
        for prop, value in (("og:url", url), ("og:locale", lang["og_locale"])):
            n = find(page.tree, "meta", property=prop)
            if n:
                reps.append((*attr_span(src, n, "content"), value))
        if page.jsonld:
            n, data = page.jsonld
            data = json.loads(json.dumps(data))
            for node in json_nodes(data):
                if "inLanguage" in node:
                    node["inLanguage"] = lang["code"]
                    if node.get("url") == base:
                        node["url"] = url
                    if isinstance(node.get("description"), str):
                        e = norm(html.escape(node["description"], quote=False))
                        key = next(k for k in page.en if page.kinds[k] == "json" and page.en[k] == e)
                        node["description"] = html.unescape(norm(strings.get(key, e)))
            text = json.dumps(data, ensure_ascii=False, indent=2).replace("</", "<\\/")
            reps.append((n.open_end, n.close_start, "\n" + text + "\n"))
        if PROFILES[lang["script"]]:
            for n in walk(page.tree.root):
                href = n.attrs.get("href") or ""
                if n.tag == "link" and "fonts.googleapis.com/css" in href:
                    q = href.split("?", 1)
                    if len(q) == 2:
                        params = [p for p in q[1].split("&") if not p.startswith("family=Figtree")]
                        reps.append((*attr_span(src, n, "href"), q[0] + "?" + "&".join(params)))
    reps.sort()
    out, pos = [], 0
    for a, b, new in reps:
        if a < pos:
            raise Fail(f"internal: overlapping replacements at {a}")
        out += [src[pos:a], new]
        pos = b
    out.append(src[pos:])
    out = "".join(out)
    if not is_en:
        out = rewrite_relative(out)
        note = (f"<!-- Generated by i18n/build.py from index.html and i18n/{lang['code']}.json. "
                "Do not edit this file: change those and re-run the build. -->\n")
        i = out.find("\n") + 1 if out.lower().startswith("<!doctype") else 0
        out = out[:i] + note + out[i:]
    return out


# ---------------------------------------------------------------- sitemap

def sitemap(old, base, built, changed, today):
    landing = {page_url(base, l): l for l in built}
    lastmod = {}
    kept = []
    for m in re.finditer(r"[ \t]*<url>.*?</url>", old, re.S):
        loc = re.search(r"<loc>(.*?)</loc>", m.group(0)).group(1).strip()
        lm = re.search(r"<lastmod>(.*?)</lastmod>", m.group(0))
        if loc in landing:
            lastmod[loc] = lm.group(1) if lm else today
        elif not re.fullmatch(re.escape(base) + r"[a-z]{2,3}(?:-[a-z]{2,4})?/", loc):
            kept.append(m.group(0))      # e.g. the compare pages; a dropped language goes away
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for loc, l in landing.items():
        lm = today if (l["code"] in changed or loc not in lastmod) else lastmod[loc]
        lines += ["  <url>", f"    <loc>{loc}</loc>", f"    <lastmod>{lm}</lastmod>"]
        for a in built:
            lines.append(f'    <xhtml:link rel="alternate" hreflang="{a["code"]}" href="{page_url(base, a)}"/>')
        lines.append(f'    <xhtml:link rel="alternate" hreflang="x-default" href="{base}"/>')
        lines.append("  </url>")
    lines += kept + ["</urlset>", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------- main

def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        raise Fail(f"{path.relative_to(ROOT)}: not valid JSON: {e}")


def dump_strings(d):
    return "{\n" + ",\n".join(f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}"
                              for k, v in d.items()) + "\n}\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="write nothing; exit 1 if anything is stale or broken")
    ap.add_argument("--lenient", action="store_true", help="fall back to English for missing or broken strings")
    args = ap.parse_args()

    langs = load_json(LANGS_FILE)
    by_code = {l["code"]: l for l in langs}
    en_lang = by_code["en"]
    files = sorted(p for p in HERE.glob("*.json") if p.name not in ("en.json", "languages.json"))
    for p in files:
        if p.stem not in by_code:
            raise Fail(f"{p.relative_to(ROOT)}: {p.stem!r} is not a code in i18n/languages.json")
    present = {p.stem for p in files}
    built = [en_lang] + [l for l in langs if l["code"] in present]

    original = SOURCE.read_text(encoding="utf-8")
    # The generated blocks go into the source first, so that extraction offsets match it.
    first = Page(original)
    src = splice_blocks(original, head_block(first, en_lang, langs, built),
                        switcher_block(first, en_lang, built, SYNTHETIC))
    page = Page(src)
    if render(page, en_lang, langs, built, page.en) != src:
        raise Fail("internal: rendering English does not reproduce index.html")
    for n in walk(page.tree.root):
        if "data-app" in n.attrs and not src[n.open_end:n.close_start].strip():
            raise Fail(f"index.html line {src.count(chr(10), 0, n.start) + 1}: <{n.tag} data-app> is empty; "
                       "put the real text in it so crawlers see it")
    warnings = [f"index.html line {src.count(chr(10), 0, n.start) + 1}: data-app-href link has href=\"#\" (crawlers see no link)"
                for n in walk(page.tree.root) if "data-app-href" in n.attrs and n.attrs.get("href") == "#"]

    outputs = {SOURCE: src, EN_FILE: dump_strings(page.en)}
    errors = []
    pages = {}
    for l in built[1:]:
        path = HERE / f"{l['code']}.json"
        strings = load_json(path)
        if not isinstance(strings, dict):
            raise Fail(f"{path.relative_to(ROOT)}: must be a JSON object of key: string")
        errs, warns, bad = check(l, strings, page)
        tag = path.relative_to(ROOT)
        if args.lenient:
            warnings += [f"{tag}: {e} (using English)" for e in errs]
            strings = {k: v for k, v in strings.items() if k not in bad}
        else:
            errors += [f"{tag}: {e}" for e in errs]
        warnings += [f"{tag}: {w}" for w in warns]
        pages[l["code"]] = render(page, l, langs, built, strings)

    for w in warnings:
        print("warning:", w, file=sys.stderr)
    if errors:
        # en.json is still written: it is what translators fix the errors against.
        if not args.check:
            write(EN_FILE, outputs[EN_FILE])
        for e in errors:
            print("error:", e, file=sys.stderr)
        print(f"\n{len(errors)} error(s); nothing else was written. "
              "Fix the strings files, or run with --lenient to publish with English fallbacks.", file=sys.stderr)
        return 1

    changed = set()
    for l in built[1:]:
        path = ROOT / l["folder"] / "index.html"
        outputs[path] = pages[l["code"]]
        if not path.exists() or path.read_text(encoding="utf-8") != pages[l["code"]]:
            changed.add(l["code"])
    if src != original:
        changed.add("en")
    old_map = SITEMAP.read_text(encoding="utf-8") if SITEMAP.exists() else ""
    outputs[SITEMAP] = sitemap(old_map, base_url(page), built, changed, datetime.date.today().isoformat())

    stale = [p for p, text in outputs.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
    for l in langs:
        if l["folder"] and l["code"] not in present and (ROOT / l["folder"] / "index.html").exists():
            print(f"warning: {l['folder']}/index.html exists but i18n/{l['code']}.json does not; delete the folder",
                  file=sys.stderr)
    names = ", ".join(l["code"] for l in built)
    if args.check:
        for p in stale:
            print("out of date:", p.relative_to(ROOT))
        print(f"{len(page.en)} strings; languages: {names}; {len(stale)} file(s) out of date")
        return 1 if stale else 0
    for p in stale:
        write(p, outputs[p])
        print("wrote", p.relative_to(ROOT))
    print(f"{len(page.en)} strings; languages: {names}; {len(stale)} file(s) changed")
    return 0


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text(encoding="utf-8") != text:
        path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Fail as e:
        print("error:", e, file=sys.stderr)
        sys.exit(1)
