#!/usr/bin/env python3
"""构造迷你 EPUB 夹具，供 abm --verify-epub-split 校验章节锚点切分。"""
from __future__ import annotations

import io
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parent / "fixtures"


def write_epub(path: Path, files: dict[str, str | bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for name, data in files.items():
            zf.writestr(name, data)


CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""


def opf(title: str, spine: list[str], nav: str | None = None, ncx: str | None = None) -> str:
    manifest = []
    spine_items = []
    if nav:
        manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    if ncx:
        manifest.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    for i, href in enumerate(spine):
        mid = f"ch{i}"
        manifest.append(f'<item id="{mid}" href="{href}" media-type="application/xhtml+xml"/>')
        spine_items.append(f'<itemref idref="{mid}"/>')
    spine_attr = ' toc="ncx"' if ncx else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:fixture</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>Tester</dc:creator>
    <dc:language>zh</dc:language>
  </metadata>
  <manifest>
    {"".join(manifest)}
  </manifest>
  <spine{spine_attr}>
    {"".join(spine_items)}
  </spine>
</package>"""


def xhtml(body: str, title: str = "doc") -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>{title}</title></head>
<body>{body}</body>
</html>"""


def build_nav_toc_split() -> None:
    nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc">
    <ol>
      <li><a href="chapter1.xhtml">第一章 引子</a>
        <ol>
          <li><a href="chapter1.xhtml#s1">第一节 启程</a></li>
          <li><a href="chapter1.xhtml#s2">第二节 风暴</a></li>
        </ol>
      </li>
      <li><a href="chapter2.xhtml">卷二</a>
        <ol>
          <li><a href="chapter2.xhtml">独立章</a></li>
        </ol>
      </li>
    </ol>
  </nav>
  <nav epub:type="page-list">
    <ol><li><a href="chapter1.xhtml#s1">页码 1</a></li></ol>
  </nav>
</body>
</html>"""
    ch1 = xhtml("""
<section id="s1"><p>启程段落甲。启程段落乙。</p></section>
<section id="s2"><p>风暴段落甲。风暴段落乙。</p></section>
""")
    ch2 = xhtml("<p>独立章</p><p>卷二正文，足够长以便统计字数。</p>")
    write_epub(OUT / "nav_toc_split.epub", {
        "META-INF/container.xml": CONTAINER,
        "OEBPS/content.opf": opf("夹具书", ["chapter1.xhtml", "chapter2.xhtml"], nav="nav.xhtml"),
        "OEBPS/nav.xhtml": nav,
        "OEBPS/chapter1.xhtml": ch1,
        "OEBPS/chapter2.xhtml": ch2,
    })


def build_no_toc() -> None:
    ch1 = xhtml("<p>甲文档正文。</p>", title="第一章 文档甲")
    ch2 = xhtml("<p>乙文档正文。</p>", title="第二章 文档乙")
    write_epub(OUT / "no_toc.epub", {
        "META-INF/container.xml": CONTAINER,
        "OEBPS/content.opf": opf("无目录", ["chapter1.xhtml", "chapter2.xhtml"]),
        "OEBPS/chapter1.xhtml": ch1,
        "OEBPS/chapter2.xhtml": ch2,
    })


def build_missing_anchor() -> None:
    nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc">
    <ol>
      <li><a href="chapter1.xhtml#s1">第一节 有效</a></li>
      <li><a href="chapter1.xhtml#ghost">幽灵节</a></li>
      <li><a href="chapter1.xhtml#s2">第二节 后继</a></li>
    </ol>
  </nav>
</body>
</html>"""
    ch1 = xhtml("""
<section id="s1"><p>有效第一节内容。</p></section>
<section id="s2"><p>第二节内容。</p></section>
""")
    write_epub(OUT / "missing_anchor.epub", {
        "META-INF/container.xml": CONTAINER,
        "OEBPS/content.opf": opf("缺失锚点", ["chapter1.xhtml"], nav="nav.xhtml"),
        "OEBPS/nav.xhtml": nav,
        "OEBPS/chapter1.xhtml": ch1,
    })


def build_pagelist_nav() -> None:
    nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>导航</title></head>
<body>
  <nav epub:type="landmarks">
    <ol><li><a href="chapter1.xhtml">封面</a></li></ol>
  </nav>
  <nav epub:type="toc">
    <ol><li><a href="chapter1.xhtml">第一章 正文</a></li></ol>
  </nav>
  <nav epub:type="page-list">
    <ol><li><a href="chapter1.xhtml">页码 1</a></li></ol>
  </nav>
</body>
</html>"""
    ch1 = xhtml("<p>第一章 正文</p><p>唯一正文段落，用于验证 landmarks/page-list 不会变成章节。</p>")
    write_epub(OUT / "pagelist_nav.epub", {
        "META-INF/container.xml": CONTAINER,
        "OEBPS/content.opf": opf("页列表", ["chapter1.xhtml"], nav="nav.xhtml"),
        "OEBPS/nav.xhtml": nav,
        "OEBPS/chapter1.xhtml": ch1,
    })


def main() -> None:
    build_nav_toc_split()
    build_no_toc()
    build_missing_anchor()
    build_pagelist_nav()
    print(f"fixtures → {OUT}")
    for p in sorted(OUT.glob("*.epub")):
        print(" ", p.name, p.stat().st_size)


if __name__ == "__main__":
    main()
