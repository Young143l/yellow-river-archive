#!/usr/bin/env python3
"""
目录填充：把 TOC 域的缓存结果写成「条目 + 右对齐点线 + 页码」
用法: python3 toc_fill.py <docx> <toc.json>
说明: 保留 Word TOC 域（begin /instrText /separate / 条目 / end），Word/WPS 打开即显示，按 F9 仍可重算。
"""
import json, re, shutil, sys, zipfile
from html import escape

TAB_POS = 8296  # 14.6cm（版心宽）对应的 twips


def entry_xml(level: int, text: str, page) -> str:
    ind = {1: 0, 2: 284, 3: 567}[level]
    bold = '<w:b/>' if level == 1 else ""  # 注意 OOXML 顺序：rFonts → b → sz（bCs/szCs 会被校验器判为非法子元素，省略）
    size = 24 if level == 1 else 22           # 12pt / 11pt
    return (
        "<w:p><w:pPr>"
        f'<w:tabs><w:tab w:val="right" w:leader="dot" w:pos="{TAB_POS}"/></w:tabs>'
        '<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>'
        f'<w:ind w:left="{ind}" w:firstLine="0"/>'
        '<w:jc w:val="left"/></w:pPr>'
        f'<w:r><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="宋体"/>{bold}'
        f'<w:sz w:val="{size}"/></w:rPr>'
        f'<w:t xml:space="preserve">{escape(text)}</w:t></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="宋体"/>'
        f'<w:sz w:val="{size}"/></w:rPr><w:tab/>'
        f'<w:t>{page}</w:t></w:r></w:p>'
    )


def main():
    docx, toc = sys.argv[1], sys.argv[2]
    data = json.load(open(toc, encoding="utf-8"))
    entries = [e for e in data["entries"] if e.get("page")]
    zin = zipfile.ZipFile(docx)
    xml = zin.read("word/document.xml").decode("utf-8")

    # 定位 TOC 域：从含 instrText 的段落起，到含 fldCharType="end" 的段落止（整段替换，保证可重复执行）
    m = re.search(r"<w:p\b[^>]*>(?:(?!</w:p>).)*?TOC \\o.*?</w:p>", xml, re.S)
    if not m:
        print("未找到 TOC 域段落", file=sys.stderr)
        sys.exit(2)
    rest = xml[m.end():]
    end_m = re.search(r'<w:p\b[^>]*>(?:(?!</w:p>).)*?<w:fldChar w:fldCharType="end"\s*/>(?:(?!</w:p>).)*?</w:p>', rest, re.S)
    span_end = m.end() + (end_m.end() if end_m else 0)
    old = xml[m.start():span_end]
    # 保留域起始段（begin + instrText + separate），去掉占位文本与 end
    ppr = re.search(r"<w:pPr>.*?</w:pPr>", old, re.S)
    head = (
        "<w:p>" + (ppr.group(0) if ppr else "")
        + '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        + '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\u </w:instrText></w:r>'
        + '<w:r><w:fldChar w:fldCharType="separate"/></w:r></w:p>'
    )
    tail = '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>' \
           '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
    body = "".join(entry_xml(e["level"], e["text"], e["page"]) for e in entries)
    xml = xml.replace(old, head + body + tail)

    tmp = docx + ".tmp"
    zout = zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED)
    for it in zin.infolist():
        zout.writestr(it, xml.encode("utf-8") if it.filename == "word/document.xml" else zin.read(it.filename))
    zout.close()
    zin.close()
    shutil.move(tmp, docx)
    print(f"{docx}: 已写入目录条目 {len(entries)} 条（域结构保留）")


main()
