#!/usr/bin/env python3
"""Generate bilingual static progress pages from reviewed public Markdown.

No network, third-party renderer or runtime content fetch is required.
"""
import argparse
import html
from pathlib import Path
import re
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://gscsdx.github.io/HmChat/'
PAGES = {
    'features': ('docs/FEATURES.md', 'docs/FEATURES.en.md', '现有功能', 'Features'),
    'roadmap': ('docs/ROADMAP.md', 'docs/ROADMAP.en.md', '路线图', 'Roadmap'),
    'changelog': ('CHANGELOG.md', 'CHANGELOG.en.md', '更新日志', 'Changelog'),
}


def link_url(target, source):
    """Allow web links, fragments and repository-relative links only."""
    parts = urlsplit(target)
    if parts.scheme:
        return target if parts.scheme in ('https', 'http') else '#'
    if parts.netloc or target.startswith('/') or '\\' in target:
        return '#'
    if target.startswith('#'):
        return target
    resolved = (ROOT / source).parent.joinpath(parts.path).resolve()
    if not resolved.is_relative_to(ROOT):
        return '#'
    relative = resolved.relative_to(ROOT).as_posix()
    suffix = '#' + parts.fragment if parts.fragment else ''
    for slug, definition in PAGES.items():
        if relative in definition[:2]:
            return slug + '.html' + suffix
    return 'https://github.com/gscsdx/HmChat/blob/main/' + relative + suffix


def inline(value, source):
    # Tokens are processed before escaping; unrecognized HTML remains plain text.
    pattern = r'`([^`]+)`|\[([^\]]+)\]\(([^\s)]+)\)|\*\*([^*]+)\*\*'
    result, cursor = [], 0
    for match in re.finditer(pattern, value):
        result.append(html.escape(value[cursor:match.start()]))
        code, label, target, strong = match.groups()
        if code is not None:
            result.append('<code>' + html.escape(code) + '</code>')
        elif label is not None:
            result.append('<a href="' + html.escape(link_url(target, source), quote=True) + '">' + html.escape(label) + '</a>')
        else:
            result.append('<strong>' + html.escape(strong) + '</strong>')
        cursor = match.end()
    result.append(html.escape(value[cursor:]))
    return ''.join(result)


def render(markdown, source):
    lines = markdown.splitlines()
    out, index = [], 0
    while index < len(lines):
        line = lines[index].strip()
        if not line:
            index += 1
            continue
        if line.startswith('|'):
            rows = []
            while index < len(lines) and lines[index].strip().startswith('|'):
                cells = [cell.strip() for cell in lines[index].strip().strip('|').split('|')]
                if not all(re.fullmatch(r':?-+:?', cell.replace(' ', '')) for cell in cells):
                    rows.append(cells)
                index += 1
            out.append('<div class="doc-table" tabindex="0" role="region" aria-label="' + ('功能与计划表' if not source.endswith('.en.md') else 'Features and plans table') + '"><table>')
            for row_index, row in enumerate(rows):
                tag = 'th' if row_index == 0 else 'td'
                if row_index == 0:
                    out.append('<thead>')
                if row_index == 1:
                    out.append('<tbody>')
                out.append('<tr>' + ''.join('<' + tag + (' scope="col"' if tag == 'th' else '') + '>' + inline(cell, source) + '</' + tag + '>' for cell in row) + '</tr>')
                if row_index == 0:
                    out.append('</thead>')
            if len(rows) > 1:
                out.append('</tbody>')
            out.append('</table></div>')
            continue
        heading = re.match(r'^(#{1,6})\s+(.+)$', line)
        if heading:
            level = len(heading[1])
            out.append(f'<h{level}>' + inline(heading[2], source) + f'</h{level}>')
        elif re.match(r'^\d+\. ', line):
            out.append('<ol>')
            while index < len(lines) and re.match(r'^\d+\. ', lines[index].strip()):
                out.append('<li>' + inline(re.sub(r'^\d+\. ', '', lines[index].strip()), source) + '</li>')
                index += 1
            out.append('</ol>')
            continue
        elif re.match(r'^[-*] ', line):
            out.append('<ul>')
            while index < len(lines) and re.match(r'^[-*] ', lines[index].strip()):
                out.append('<li>' + inline(lines[index].strip()[2:], source) + '</li>')
                index += 1
            out.append('</ul>')
            continue
        elif line == '---':
            out.append('<hr>')
        else:
            paragraph = [line]
            while index + 1 < len(lines) and lines[index + 1].strip() and not re.match(r'^(#|\||[-*] |\d+\. )', lines[index + 1].strip()):
                index += 1
                paragraph.append(lines[index].strip())
            out.append('<p>' + inline(' '.join(paragraph), source) + '</p>')
        index += 1
    return '\n'.join(out)


def generate():
    home = (ROOT / 'website/index.html').read_text()
    prefix = home.split('  <main id="main">')[0]
    footer = home[home.index('  <footer class="site-footer'):]
    outputs = {}
    for slug, (zh, en, title, english_title) in PAGES.items():
        document = prefix.replace('<body>', f'<body data-page="{slug}">')
        document = document.replace('href="#"', 'href="index.html"')
        document = document.replace(' aria-current="page"', '')
        document = document.replace(f'href="{slug}.html"', f'href="{slug}.html" aria-current="page"')
        document = re.sub(r'<title>.*?</title>', f'<title>{title} | HmChat</title>', document)
        description = f'HmChat {title}：实现范围、验证与后续计划。'
        for key in ('name="description"', 'property="og:description"'):
            document = re.sub(r'(' + key + r' content=")[^"]*', r'\g<1>' + description, document)
        document = re.sub(r'(property="og:title" content=")[^"]*', r'\g<1>' + title + ' | HmChat', document)
        for key in ('property="og:url" content="', 'rel="canonical" href="'):
            document = document.replace(key + BASE + '"', key + BASE + slug + '.html"')
        document += '  <main id="main" class="doc-layout container">\n'
        for language, source in [('zh', zh), ('en', en)]:
            hidden = ' hidden' if language == 'en' else ''
            document += f'<article class="doc-content" data-doc-language="{language}" lang="{"zh-CN" if language == "zh" else "en"}"{hidden}>\n'
            document += render((ROOT / source).read_text(), source) + '\n</article>\n'
        document += '  </main>\n' + footer.replace('href="#"', 'href="index.html"')
        outputs['website/' + slug + '.html'] = document
    urls = [BASE] + [BASE + slug + '.html' for slug in PAGES]
    outputs['website/sitemap.xml'] = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + ''.join('  <url><loc>' + url + '</loc></url>\n' for url in urls) + '</urlset>\n'
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Fail when generated pages are stale')
    args = parser.parse_args()
    stale = []
    for name, content in generate().items():
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(name)
        else:
            path.write_text(content)
    if stale:
        parser.exit(1, 'Regenerate with python3 scripts/build-website.py: ' + ', '.join(stale) + '\n')
    print('Website documentation is up to date.' if args.check else 'Generated three bilingual progress pages and sitemap.')


if __name__ == '__main__':
    main()
