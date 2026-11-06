#!/usr/bin/env python3
"""
目录页码测量：WPS(word2pdf) 分页 + pypdf 逐页取文 → 标题→页码映射
用法: python3 toc_measure.py <docx> <out.json>
依赖: /tmp/venv-pdf/bin/python（含 pypdf）、wpscli
"""
import json, re, subprocess, sys, os, zipfile
from html import unescape

WPS = "/Applications/wpsoffice.app/Contents/MacOS/wpscli"
PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".venv-pdf", "bin", "python")
if not os.path.exists(PY):
    PY = "python3"   # 兜底：项目内 venv 缺失时用系统 python（需已安装 pypdf）


def norm(s: str) -> str:
    return re.sub(r"\s+", "", s)


def headings_of(docx: str):
    """按文档顺序抽取 Heading1/2/3 段落文本"""
    xml = zipfile.ZipFile(docx).read("word/document.xml").decode("utf-8")
    out = []
    for p in re.findall(r"<w:p\b.*?</w:p>", xml, re.S):
        m = re.search(r'<w:pStyle w:val="Heading(\d)"', p)
        if not m:
            continue
        level = int(m.group(1))
        if level > 3:
            continue
        text = unescape("".join(re.findall(r"<w:t[^>]*>(.*?)</w:t>", p, re.S)))
        if text.strip():
            out.append({"level": level, "text": text.strip()})
    return out


def page_texts(pdf: str):
    """用 pypdf 逐页取文本"""
    code = (
        "from pypdf import PdfReader;import json,sys;"
        "r=PdfReader(sys.argv[1]);"
        "print(json.dumps([p.extract_text() or '' for p in r.pages],ensure_ascii=False))"
    )
    res = subprocess.run([PY, "-c", code, pdf], capture_output=True, text=True, check=True)
    return json.loads(res.stdout)


def main():
    docx, out = sys.argv[1], sys.argv[2]
    force_pages = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    work = os.path.join(os.path.dirname(os.path.abspath(docx)), ".work", "wps")
    os.makedirs(work, exist_ok=True)
    base = os.path.splitext(os.path.basename(docx))[0]
    pdf = os.path.join(work, base + ".pdf")
    if os.path.exists(pdf):
        os.remove(pdf)
    subprocess.run([WPS, "word2pdf", docx, "-o", pdf], capture_output=True)
    if not os.path.exists(pdf):
        print("转换失败：", pdf, file=sys.stderr)
        sys.exit(2)
    pages = [norm(t) for t in page_texts(pdf)]
    heads = headings_of(docx)
    toc_pages = force_pages or (2 if len(heads) > 50 else 1)   # 目录本身占用页数（经验值，见 AGENTS.md）
    start = 0
    for i, t in enumerate(pages):                     # 定位“目录”所在页
        if "目录" in t:
            start = i + toc_pages
            break
    cur = start
    missing = []
    for h in heads:
        key = norm(h["text"])
        found = None
        for i in range(cur, len(pages)):
            if key in pages[i]:
                found = i + 1
                break
        if found is None:
            missing.append(h["text"])
            h["page"] = None
        else:
            h["page"] = found
            cur = found - 1                            # 单调前进（允许同页多标题）
    json.dump({"doc": base, "pages": len(pages), "tocStart": start + 1, "entries": heads},
              open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    ok = sum(1 for h in heads if h["page"])
    print(f"{base}: PDF {len(pages)} 页，标题 {len(heads)} 条，定位成功 {ok} 条"
          + (f"，未定位 {missing}" if missing else ""))
    for h in heads[:6]:
        print(f"   L{h['level']} p{h['page']} {h['text'][:34]}")


main()
