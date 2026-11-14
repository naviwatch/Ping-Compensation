"""Turn a Markdown brief into a print-ready HTML page, which handout_pdf.bat then prints to PDF.

Only the Markdown the playtest handout uses is supported: headings, paragraphs, bold, inline code,
links, bulleted and numbered lists, pipe tables and fenced code blocks. Standard library only.

Usage: python handout_to_html.py <brief.md> > page.html

The page goes to stdout on purpose: Microsoft Store Python may redirect files it creates under
AppData to a private folder the browser can't see, while a shell redirect writes the real file.
"""
import html
import re
import sys

HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
LIST_ITEM = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")
BLOCK_START = re.compile(r"^(#{1,6}\s|```|\s*\||\s*([-*]|\d+\.)\s)")
SEPARATOR_CELL = re.compile(r"^:?-+:?$")
CODE_SPAN = re.compile(r"`([^`]+)`")
LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
BOLD = re.compile(r"\*\*(.+?)\*\*")
WHOLLY_BOLD = re.compile(r"\*\*[^*]+\*\*")
FILE_NAME = re.compile(r"^[\w./-]+\.\w+$")
PLACEHOLDER = re.compile(r"\x00(\d+)\x00")
LONG_CODE = 32 # inline code longer than this may wrap across lines

# @page margin boxes (the footer) need Edge or Chrome 131 or later.
CSS = """
@page {
	size: A4;
	margin: 17mm 17mm 19mm 17mm;
	background: #16181d;

	@bottom-left {
		content: "Ping Compensation \\00B7  playtest handout";
		font-family: "Segoe UI", Arial, sans-serif;
		font-size: 8pt;
		color: #7d838d;
	}

	@bottom-right {
		content: "Page " counter(page) " of " counter(pages);
		font-family: "Segoe UI", Arial, sans-serif;
		font-size: 8pt;
		color: #7d838d;
	}
}

html {
	-webkit-print-color-adjust: exact;
	print-color-adjust: exact;
	background: #16181d;
}

body {
	margin: 0;
	background: #16181d;
	color: #d5d8de;
	font-family: "Segoe UI", Arial, sans-serif;
	font-size: 10.5pt;
	line-height: 1.45;
}

h1 {
	margin: 0 0 8pt;
	color: #f1f3f6;
	font-size: 21pt;
	font-weight: 700;
	line-height: 1.2;
	letter-spacing: -0.2pt;
}

h2 {
	margin: 18pt 0 6pt;
	padding-bottom: 3pt;
	border-bottom: 1px solid #4a3532;
	color: #f09a8a;
	font-size: 13.5pt;
	font-weight: 600;
	line-height: 1.25;
	break-after: avoid;
}

h3 {
	margin: 12pt 0 4pt;
	color: #eceef2;
	font-size: 11.5pt;
	font-weight: 600;
	break-after: avoid;
}

p {
	margin: 0 0 7pt;
}

p.lead {
	margin: 11pt 0 4pt;
	break-after: avoid;
}

/* A line that introduces a box, table or list stays on the same page as it. */
p:has(+ pre),
p:has(+ table),
p:has(+ ul),
p:has(+ ol) {
	break-after: avoid;
}

a {
	color: #8fb8ff;
}

strong {
	color: #f1f3f6;
	font-weight: 600;
}

ul,
ol {
	margin: 0 0 8pt;
	padding-left: 18pt;
}

li {
	margin: 0 0 3.5pt;
	padding-left: 2pt;
	break-inside: avoid;
}

code {
	padding: 0 3px;
	border: 1px solid #353a44;
	border-radius: 3px;
	background: #22262e;
	color: #e7e9ed;
	font-family: Consolas, "Cascadia Mono", monospace;
	font-size: 9.2pt;
	white-space: nowrap;
}

/* Only long snippets may wrap, so short commands and file names stay whole. */
code.long {
	white-space: normal;
	overflow-wrap: anywhere;
}

pre {
	margin: 4pt 0 10pt;
	padding: 8pt 10pt;
	border: 1px solid #353a44;
	border-radius: 4px;
	background: #1e2128;
	color: #e7e9ed;
	font-family: Consolas, "Cascadia Mono", monospace;
	font-size: 9.3pt;
	line-height: 1.5;
	white-space: pre-wrap;
	break-inside: avoid;
}

table {
	width: 100%;
	margin: 4pt 0 10pt;
	border-collapse: collapse;
	font-size: 9.8pt;
}

th,
td {
	padding: 5pt 7pt;
	border: 1px solid #353a44;
	text-align: left;
	vertical-align: top;
}

th {
	background: #22262e;
	color: #f1f3f6;
	font-weight: 600;
}

td:first-child {
	width: 34%;
}

tr {
	break-inside: avoid;
}
"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{{TITLE}}</title>
<style>{{CSS}}</style>
</head>
<body>
{{BODY}}
</body>
</html>
"""


def smart_quotes(text):
	out = []
	previous = " "

	for char in text:
		if char == '"':
			out.append("“" if previous in " \t([{" else "”")
		elif char == "'":
			out.append("‘" if previous in " \t([{" else "’")
		else:
			out.append(char)

		previous = char

	return "".join(out)


def inline(text):
	stash = []

	def keep(fragment):
		stash.append(fragment)

		return "\x00%d\x00" % (len(stash) - 1)

	def code(m):
		snippet = m.group(1)
		css_class = ' class="long"' if len(snippet) > LONG_CODE else ""

		return keep("<code%s>%s</code>" % (css_class, html.escape(snippet, quote=False)))

	text = CODE_SPAN.sub(code, text)

	def link(m):
		label, href = m.group(1), m.group(2)

		if re.match(r"^https?://", href):
			return keep('<a href="%s">%s</a>' % (html.escape(href), smart_quotes(html.escape(label, quote=False))))

		# A relative link points into the repository, which a reader of the PDF doesn't have.
		if FILE_NAME.match(label):
			return keep("<code>%s</code>" % html.escape(label, quote=False))

		return keep(smart_quotes(html.escape(label, quote=False)))

	text = LINK.sub(link, text)
	text = smart_quotes(html.escape(text, quote=False))
	text = BOLD.sub(r"<strong>\1</strong>", text)

	return PLACEHOLDER.sub(lambda m: stash[int(m.group(1))], text)


def split_row(row):
	row = row.strip()

	if row.startswith("|"):
		row = row[1:]

	if row.endswith("|"):
		row = row[:-1]

	cells, current, in_code = [], [], False

	for char in row:
		if char == "`":
			in_code = not in_code

		if char == "|" and not in_code:
			cells.append("".join(current).strip())
			current = []
		else:
			current.append(char)

	cells.append("".join(current).strip())

	return cells


def render(markdown):
	lines = markdown.splitlines()
	out = []
	title = None
	i = 0

	while i < len(lines):
		line = lines[i]

		if not line.strip():
			i += 1

			continue

		# An HTML comment on a line of its own, such as the tally's markers, isn't shown.
		if line.strip().startswith("<!--") and line.strip().endswith("-->"):
			i += 1

			continue

		if line.startswith("```"):
			body = []
			i += 1

			while i < len(lines) and not lines[i].startswith("```"):
				body.append(lines[i])
				i += 1

			i += 1
			out.append("<pre>%s</pre>" % html.escape("\n".join(body), quote=False))

			continue

		m = HEADING.match(line)

		if m:
			level = len(m.group(1))

			if level == 1 and title is None:
				title = m.group(2)

			out.append("<h%d>%s</h%d>" % (level, inline(m.group(2)), level))
			i += 1

			continue

		if line.lstrip().startswith("|"):
			rows = []

			while i < len(lines) and lines[i].lstrip().startswith("|"):
				rows.append(split_row(lines[i]))
				i += 1

			header = rows[0]
			body = [row for row in rows[1:] if not all(SEPARATOR_CELL.match(cell) for cell in row)]
			head_html = "".join("<th>%s</th>" % inline(cell) for cell in header)
			body_html = "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % inline(cell) for cell in row) for row in body)
			out.append("<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>" % (head_html, body_html))

			continue

		m = LIST_ITEM.match(line)

		if m:
			indent = m.group(1)
			ordered = m.group(2)[0].isdigit()
			start = int(m.group(2)[:-1]) if ordered else 1
			items = []

			while i < len(lines):
				item = LIST_ITEM.match(lines[i])

				if item and item.group(1) == indent and item.group(2)[0].isdigit() == ordered:
					items.append(item.group(3))
				elif lines[i].strip() and lines[i][:1] in " \t" and items:
					items[-1] += " " + lines[i].strip()
				else:
					break

				i += 1

			tag = "ol" if ordered else "ul"
			start_attribute = ' start="%d"' % start if ordered and start != 1 else ""
			out.append("<%s%s>%s</%s>" % (tag, start_attribute, "".join("<li>%s</li>" % inline(item) for item in items), tag))

			continue

		paragraph = []

		while i < len(lines) and lines[i].strip() and not BLOCK_START.match(lines[i]):
			paragraph.append(lines[i].strip())
			i += 1

		if not paragraph:
			paragraph.append(line.strip())
			i += 1

		text = " ".join(paragraph)
		css_class = ' class="lead"' if WHOLLY_BOLD.fullmatch(text) else ""
		out.append("<p%s>%s</p>" % (css_class, inline(text)))

	return title, "\n".join(out)


def main():
	if len(sys.argv) != 2:
		sys.stderr.write("Usage: python handout_to_html.py <brief.md> > page.html\n")
		sys.exit(2)

	with open(sys.argv[1], encoding="utf-8") as handle:
		title, body = render(handle.read())

	page = PAGE.replace("{{TITLE}}", html.escape(title or "Handout")).replace("{{CSS}}", CSS).replace("{{BODY}}", body)

	sys.stdout.buffer.write(page.encode("utf-8"))


if __name__ == "__main__":
	main()
