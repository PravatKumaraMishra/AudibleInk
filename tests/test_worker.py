import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from worker import markdown_chunks

class MarkdownTests(unittest.TestCase):
    def test_clean_markup_and_skip_code(self):
        source = '---\ntitle: Private\n---\n# Hello\n\nRead **this** [article](https://example.com).\n\n```python\nsecret()\n```\n'
        self.assertEqual(markdown_chunks(source), ['Hello', 'Read this article.'])
        self.assertIn('secret()', markdown_chunks(source, include_code=True))

    def test_preserve_content_and_bound_memory(self):
        source = ' '.join(['A sentence.'] * 1000)
        chunks = markdown_chunks(source)
        self.assertTrue(all(len(c) <= 360 for c in chunks))
        self.assertEqual(' '.join(chunks), source)

    def test_long_unbroken_word_and_empty(self):
        self.assertEqual(''.join(markdown_chunks('x' * 1000)), 'x' * 1000)
        self.assertEqual(markdown_chunks('  \n```py\nprint(1)\n```'), [])

    def test_inline_code_image_and_list(self):
        self.assertEqual(markdown_chunks('- Use `pip`.\n- ![A cat](cat.png)'), ['Use pip.', 'A cat'])


class PreviewTests(unittest.TestCase):
    def test_full_markdown_and_anchors(self):
        from document import prepare_document
        result = prepare_document('# Heading\n\nRead **bold** and `code`.\n\n- one\n- two\n\n> quote\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```py\nprint(1)\n```')
        for tag in ('<h1>', '<strong>', '<code>', '<ul>', '<blockquote>', '<table>', '<pre>'):
            self.assertIn(tag, result['html'])
        for i in range(len(result['chunks'])):
            self.assertIn(f'data-chunk="{i}"', result['html'])
        self.assertNotIn('print(1)', result['chunks'])

    def test_formatted_chunk_alignment(self):
        from document import prepare_document
        from html.parser import HTMLParser
        class Extractor(HTMLParser):
            def __init__(self):
                super().__init__(); self.index = None; self.parts = {}
            def handle_starttag(self, tag, attrs):
                attrs = dict(attrs)
                if 'data-chunk' in attrs: self.index = int(attrs['data-chunk'])
            def handle_endtag(self, tag):
                if tag == 'span': self.index = None
            def handle_data(self, text):
                if self.index is not None: self.parts[self.index] = self.parts.get(self.index, '') + text
        source = 'A **formatted sentence.** ' * 90
        result = prepare_document(source)
        parser = Extractor(); parser.feed(result['html'])
        import re
        for i, chunk in enumerate(result['chunks']):
            self.assertEqual(re.sub(r'\s+', ' ', parser.parts[i]).strip(), chunk)

    def test_no_executable_user_html_or_remote_images(self):
        from document import prepare_document
        html = prepare_document('Read <script>alert(1)</script> this.\n\n![alt](https://example.com/track.png)')['html']
        self.assertNotIn('<script', html)
        self.assertNotIn('<img', html)
        self.assertNotIn('track.png', html)

    def test_pronunciation_overrides(self):
        from document import pronunciation_text
        result = pronunciation_text('API APIs JSON getMapping → SQL.', 'API = A P I\nJSON = jay son\nSQL = sequel')
        self.assertEqual(result, 'A P I APIs jay son get Mapping  then  sequel.')
        self.assertEqual(pronunciation_text('C++ and .NET', 'C++ = C plus plus\n.NET = dot net'), 'C plus plus and dot net')


if __name__ == '__main__':
    unittest.main()
