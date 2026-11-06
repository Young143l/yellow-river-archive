#!/usr/bin/env python3
"""
目录流水线：测量 → 填充 → 复测，直至页码收敛
用法: python3 toc_pipeline.py <docx> [maxIter]
"""
import json, os, subprocess, sys

WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)))
MEASURE = os.path.join(WORK, "toc_measure.py")
FILL = os.path.join(WORK, "toc_fill.py")


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("命令失败:", " ".join(cmd), r.stdout[-300:], r.stderr[-300:])
        sys.exit(3)
    return r.stdout.strip()


def pages_of(path):
    d = json.load(open(path, encoding="utf-8"))
    return {e["text"]: e.get("page") for e in d["entries"]}, d


def main():
    docx = sys.argv[1]
    max_iter = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    tag = os.path.splitext(os.path.basename(docx))[0]
    tmp = os.path.join(WORK, f"toc-{tag}.json")
    prev = None
    for it in range(1, max_iter + 1):
        force = "1" if it == 1 else ""          # 第 1 轮：目录尚未填充，只占 1 页
        cmd = ["python3", MEASURE, docx, tmp] + ([force] if force else [])
        out = run(cmd)
        print(f"  [{tag}] 第 {it} 轮测量: {out.splitlines()[0]}")
        cur, data = pages_of(tmp)
        if prev is not None and cur == prev:
            print(f"  [{tag}] 页码已收敛（{len(cur)} 条）")
            return 0
        run(["python3", FILL, docx, tmp])
        prev = cur
    print(f"  [{tag}] 未在 {max_iter} 轮内收敛")
    return 1


sys.exit(main())
