"""One Markdown parse supplies both the rendered preview and its speech anchors."""
from html import escape
import re
from bisect import bisect_right
from markdown_it import MarkdownIt


def split_text(text, limit=360):
    text = re.sub(r'\s+', ' ', text).strip()
    chunks = []
    while len(text) > limit:
        split = max(text.rfind('. ', 0, limit), text.rfind('! ', 0, limit), text.rfind('? ', 0, limit))
        if split < limit // 3:
            split = text.rfind(' ', 0, limit)
        split = limit - 1 if split < 1 else split
        split += 1
        chunks.append(text[:split].strip())
        text = text[split:].strip()
    if text:
        chunks.append(text)
    return chunks


def annotated_parts(parts, chunks, first):
    """Map original inline text, including formatting boundaries, to speech chunks."""
    raw = ''.join(parts)
    normalized = re.sub(r'\s+', ' ', raw).strip()
    if not normalized or not chunks:
        return [escape(p) for p in parts]
    starts, offset = [], 0
    for chunk in chunks:
        pos = normalized.find(chunk, offset)
        starts.append(pos)
        offset = pos + len(chunk)
    # Map every source character to its collapsed-whitespace text offset.
    mapping, pos, in_space = [], -1, True
    for char in raw:
        if char.isspace():
            if not in_space:
                pos += 1
            in_space = True
        else:
            pos += 1
            in_space = False
        mapping.append(max(0, min(pos, len(normalized) - 1)))
    rendered, cursor = [], 0
    for part in parts:
        groups = []
        for char in part:
            index = first + max(0, bisect_right(starts, mapping[cursor]) - 1)
            cursor += 1
            if groups and groups[-1][0] == index:
                groups[-1][1] += char
            else:
                groups.append([index, char])
        rendered.append(''.join(f'<span class="passage" data-chunk="{i}">{escape(text)}</span>' for i, text in groups))
    return rendered


def prepare_document(source, include_code=False, limit=360):
    source = re.sub(r'\A---\s*\n.*?\n---\s*(?:\n|$)', '', source, flags=re.S)
    md = MarkdownIt('commonmark', {'html': True}).enable('table')
    tokens = md.parse(source)
    chunks = []
    for token in tokens:
        if token.type == 'inline':
            children = token.children or []
            parts = [child.content if child.type in ('text', 'code_inline', 'image') else ' ' if child.type in ('softbreak', 'hardbreak') else '' for child in children]
            block = split_text(''.join(parts), limit)
            token.meta['parts'] = annotated_parts(parts, block, len(chunks))
            chunks.extend(block)
            token.type = 'reading_inline'
        elif token.type in ('fence', 'code_block'):
            block = split_text(token.content, limit) if include_code else []
            token.meta['rendered'] = annotated_parts([token.content], block, len(chunks))[0]
            chunks.extend(block)

    def inline(tokens, idx, options, env):
        token = tokens[idx]
        output = []
        for i, child in enumerate(token.children or []):
            piece = token.meta['parts'][i]
            if child.type == 'code_inline':
                output.append('<code>' + piece + '</code>')
            elif child.type in ('text', 'image', 'softbreak', 'hardbreak'):
                output.append(piece)
            elif child.type != 'html_inline':
                rule = md.renderer.rules.get(child.type)
                output.append(rule(token.children, i, options, env) if rule else md.renderer.renderToken(token.children, i, options, env))
        return ''.join(output)

    md.renderer.rules['reading_inline'] = inline
    md.renderer.rules['fence'] = lambda ts, i, op, en: '<pre><code>' + ts[i].meta['rendered'] + '</code></pre>\n'
    md.renderer.rules['code_block'] = md.renderer.rules['fence']
    md.renderer.rules['html_block'] = lambda *args: ''
    return {'chunks': chunks, 'html': md.renderer.render(tokens, md.options, {})}


def pronunciation_text(text, overrides, technical=True):
    rules = {}
    for line in overrides.splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            term, spoken = (p.strip() for p in line.split('=', 1))
            if term and spoken:
                rules[term] = spoken
    if rules:
        pattern = r'(?<!\w)(' + '|'.join(re.escape(k) for k in sorted(rules, key=len, reverse=True)) + r')(?!\w)'
        text = re.sub(pattern, lambda m: rules[m.group(0)], text)
    if technical:
        text = re.sub(r'([a-z])([A-Z])', r'\1 \2', text)
        text = text.replace('→', ' then ').replace('=>', ' becomes ').replace('!=', ' not equal to ').replace('==', ' equals ')
    return text
