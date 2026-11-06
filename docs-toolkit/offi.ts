/**
 * officecli 批量构建辅助库
 * 生成 batch JSON 并执行，统一控制字体、三线表、页脚页码、插图
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export type Props = Record<string, string | number | boolean>;
export interface Op {
  command: string;
  parent?: string;
  path?: string;
  type?: string;
  props?: Props;
  from?: string;
}

const TWIP_PER_CM = 567;

export class Doc {
  ops: Op[] = [];
  private pIdx = 0;
  private tblIdx = 0;

  /** 文档初始化：默认字体、标题样式、页面设置、页脚页码 */
  bootstrap(opts: { titlePage?: boolean; footer?: boolean } = {}) {
    const { titlePage = true, footer = true } = opts;
    this.ops.push({
      command: "set",
      path: "/",
      props: {
        "docDefaults.font": "Times New Roman",
        "docDefaults.font.hAnsi": "Times New Roman",
        "docDefaults.font.eastAsia": "宋体",
        "docDefaults.fontSize": "12pt",
        updateFields: true,
      },
    });
    // 中文排版：关闭 Word 自动中英文/数字间距（避免与正文中已写的空格叠加），并允许西文在单词中间换行以减少两端对齐的字距拉伸
    this.ops.push({
      command: "set",
      path: "/styles/Normal",
      props: { wordWrap: true, autoSpaceDE: false, autoSpaceDN: false },
    });
    // 标题样式（黑体，分级字号；outlineLvl 保证导航窗格可用）
    this.ops.push({
      command: "add",
      parent: "/styles",
      type: "style",
      props: {
        id: "Heading1", name: "heading 1", basedOn: "Normal", next: "Normal", qFormat: true, outlineLvl: 0,
        "font.ea": "黑体", "font.latin": "Times New Roman", size: "16pt", bold: true,
        align: "center", spaceBefore: "18pt", spaceAfter: "12pt",
      },
    });
    this.ops.push({
      command: "add",
      parent: "/styles",
      type: "style",
      props: {
        id: "Heading2", name: "heading 2", basedOn: "Normal", next: "Normal", qFormat: true, outlineLvl: 1,
        "font.ea": "黑体", "font.latin": "Times New Roman", size: "14pt", bold: true,
        align: "left", spaceBefore: "12pt", spaceAfter: "6pt",
      },
    });
    this.ops.push({
      command: "add",
      parent: "/styles",
      type: "style",
      props: {
        id: "Heading3", name: "heading 3", basedOn: "Normal", next: "Normal", qFormat: true, outlineLvl: 2,
        "font.ea": "黑体", "font.latin": "Times New Roman", size: "12pt", bold: true,
        align: "left", spaceBefore: "6pt", spaceAfter: "3pt",
      },
    });
    // 页面设置 A4 + 页边距
    this.ops.push({
      command: "set",
      path: "/section[1]",
      props: {
        pageWidth: "21cm", pageHeight: "29.7cm",
        marginTop: "2.54cm", marginBottom: "2.54cm",
        marginLeft: "3.17cm", marginRight: "3.17cm",
        titlePage,
      },
    });
    // 页脚页码（宋体五号居中；首页不显示）
    if (footer) {
      this.ops.push({ command: "add", parent: "/", type: "footer", props: { type: "default", align: "center", text: "", "font.ea": "宋体", size: "10.5pt" } });
      this.ops.push({ command: "add", parent: "/footer[1]", type: "field", props: { fieldType: "page" } });
      // 删除页脚中的空首段，仅保留含页码的段落
      this.ops.push({ command: "remove", path: "/footer[1]/p[1]" });
    }
  }

  /* ---------------- 段落 ---------------- */
  para(text: string, props: Props = {}): string {
    this.ops.push({ command: "add", parent: "/body", type: "paragraph", props: { text, ...props } });
    return `/body/p[${++this.pIdx}]`;
  }

  /** 一级标题（黑体三号居中） */
  h1(text: string, props: Props = {}) {
    return this.para(text, { style: "Heading1", align: "center", bold: true, size: "16pt", "font.ea": "黑体", spaceBefore: "18pt", spaceAfter: "12pt", keepNext: true, ...props });
  }
  /** 二级标题（黑体四号左对齐） */
  h2(text: string, props: Props = {}) {
    return this.para(text, { style: "Heading2", align: "left", bold: true, size: "14pt", "font.ea": "黑体", spaceBefore: "12pt", spaceAfter: "6pt", keepNext: true, ...props });
  }
  /** 三级标题（黑体小四左对齐） */
  h3(text: string, props: Props = {}) {
    return this.para(text, { style: "Heading3", align: "left", bold: true, size: "12pt", "font.ea": "黑体", spaceBefore: "6pt", spaceAfter: "3pt", keepNext: true, ...props });
  }
  /** 正文段落（宋体小四、1.5 倍行距、首行缩进 2 字符） */
  body(text: string, props: Props = {}) {
    return this.para(text, { size: "12pt", lineSpacing: "1.5x", lineRule: "auto", firstLineIndent: "24pt", align: "justify", spaceAfter: "0pt", ...props });
  }
  /** 无首行缩进的正文段落（用于列表式内容） */
  bodyPlain(text: string, props: Props = {}) {
    return this.para(text, { size: "12pt", lineSpacing: "1.5x", lineRule: "auto", align: "justify", spaceAfter: "0pt", ...props });
  }
  /** 空行 */
  gap(size = "12pt") {
    return this.para("", { size });
  }
  /** 表格题注（表上方，黑体五号居中）——下一张表将把题注并入表首合并行 */
  private pendingCaption: string | null = null;
  tableCaption(text: string) {
    this.pendingCaption = text;
  }
  /** 图题注（图下方，黑体五号居中） */
  figCaption(text: string) {
    return this.para(text, { align: "center", bold: true, size: "10.5pt", "font.ea": "黑体", spaceBefore: "6pt", spaceAfter: "12pt", firstLineIndent: "0pt" });
  }
  /** 封面信息行（宋体四号居中） */
  coverLine(text: string, size = "14pt", props: Props = {}) {
    return this.para(text, { align: "center", size, "font.ea": "黑体", spaceAfter: "6pt", ...props });
  }

  /**
   * 学院风填报式封面（四次实验报告统一模板）——v3 定稿版
   * 校徽 → 校名 → 双分隔线 → 课程名 → 文档名 → 阶段标识 → 信息填报区（含项目名） → 日期
   */
  cover(o: {
    docTitle: string;
    stage: string;
    project: string;
    group: string;
    leader: string;
    members: string;
    college: string;
    majorClass: string;
    teacher: string;
    date: string;
    logo?: string;
  }) {
    this.para("　", { align: "center", size: "40pt", spaceAfter: "0pt", lineSpacing: "1.0x", lineRule: "auto" });
    this.para("软件文档写作课程", { align: "center", size: "14pt", "font.ea": "黑体", spaceAfter: "30pt", lineSpacing: "1.0x", lineRule: "auto" });
    this.para(o.docTitle, { align: "center", bold: true, size: "38pt", "font.ea": "黑体", spaceAfter: "22pt", lineSpacing: "1.0x", lineRule: "auto" });
    this.para(o.stage, { align: "center", size: "16pt", "font.ea": "黑体", spaceAfter: "196pt", lineSpacing: "1.0x", lineRule: "auto" });
    // 信息填报区：两列无边框表格，值列下划线；首行为项目名称
    const lines: [string, string][] = [
      ["项目名称：", o.project],
      ["组　　长：", o.leader],
      ["小组成员：", o.members],
      ["学　　院：", o.college],
      ["专业班级：", o.majorClass],
      ["指导教师：", o.teacher],
    ];
    const n = ++this.tblIdx;
    const labelW = Math.round(2.5 * TWIP_PER_CM);
    const valueW = Math.round(9.7 * TWIP_PER_CM);
    const csv = lines.map(([l, v]) => `${l},${v}`).join(";");
    this.ops.push({ command: "add", parent: "/body", type: "table", props: { data: csv, width: "12.2cm", layout: "fixed", colWidths: `${labelW},${valueW}`, align: "center" } });
    this.ops.push({ command: "set", path: `/body/tbl[${n}]`, props: { "border.all": "none" } });
    lines.forEach((_, ri) => {
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri + 1}]/tc[1]`, props: { size: "11pt", align: "right", valign: "center", lineSpacing: "1.0x", lineRule: "auto" } });
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri + 1}]/tc[2]`, props: { size: "11pt", align: "left", valign: "center", lineSpacing: "1.0x", lineRule: "auto", "border.bottom": "single;4;000000" } });
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri + 1}]`, props: { cantSplit: true } });
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri + 1}]/tc[1]/p[1]`, props: { keepNext: true } });
    });
    // 日期落款
    this.para(o.date, { align: "center", size: "14pt", "font.ea": "宋体", spaceBefore: "120pt", spaceAfter: "0pt", lineSpacing: "1.0x", lineRule: "auto" });
  }

  /** Word 目录域（打开文档时由 Word 自动重建条目） */
  toc(props: Props = {}) {
    this.ops.push({ command: "add", parent: "/", type: "toc", props: { levels: "1-3", hyperlinks: true, pageNumbers: true, ...props } });
    // 目录域本身占一个段落，必须计入段落序号，否则后续 /body/p[N] 全部偏移一位
    this.pIdx += 1;
  }

  /* ---------------- 三线表/网格表 ---------------- */
  /**
   * 生成三线表：顶线/底线 1.5 磅，表头下线 0.75 磅，无竖线、无底纹
   * @param rows 二维数组（仅支持全角标点，避免半角逗号/分号）
   * @param weights 各列相对宽度
   * @param aligns 各列对齐方式，缺省居中
   * @param opts.size 表内字号（默认 10.5pt）
   * @param opts.grid 网格表（全边框，用于分工表等），默认三线表
   * @param opts.keepTogether 整表不拆页（默认 true）
   */
  table(rows: string[][], weights: number[], aligns?: ("center" | "left")[], opts: { size?: string; grid?: boolean; keepTogether?: boolean; caption?: string } = {}) {
    const size = opts.size ?? "10.5pt";
    // 表题：取出待用题注，作为表格首行合并单元格（任何分页情况下都不会与表格分离）
    if (this.pendingCaption && !opts.caption) {
      opts = { ...opts, caption: this.pendingCaption };
      this.pendingCaption = null;
    }
    const n = ++this.tblIdx;
    const cols = rows[0].length;
    const hasCaption = !!opts.caption;
    const allRows: string[][] = hasCaption
      ? [[opts.caption as string, ...Array(Math.max(0, cols - 1)).fill("")], ...rows]
      : rows;
    const totalRows = allRows.length;
    const headerRow = hasCaption ? 2 : 1; // 列标题所在行（1-based）
    const total = weights.reduce((a, b) => a + b, 0);
    const colWidths = weights.map((w) => Math.round((w / total) * 14.6 * TWIP_PER_CM)).join(",");
    // CSV 转义：单元格内含半角逗号/分号/引号时必须加引号，否则会被误拆成多列
    const cell = (v: string) => (/[",;]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
    const csv = allRows.map((r) => r.map(cell).join(",")).join(";");
    this.ops.push({ command: "add", parent: "/body", type: "table", props: { data: csv, width: "14.6cm", layout: "fixed", colWidths } });
    // 表题行合并为一格（黑体加粗居中）
    if (hasCaption) {
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[1]/tc[1]`, props: { colspan: cols, bold: true, align: "center", valign: "center", size } });
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[1]/tc[1]/p[1]`, props: { "font.ea": "黑体", "font.latin": "Times New Roman" } });
    }
    // 边框
    if (opts.grid) {
      // 网格表：全边框 0.75 磅黑色，无底纹、无彩色
      this.ops.push({ command: "set", path: `/body/tbl[${n}]`, props: { "border.all": "single;6;000000" } });
      if (hasCaption) this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[1]/tc[1]`, props: { "border.all": "none" } });
    } else {
      // 三线表：顶线/底线 1.5 磅，表头下线 0.75 磅
      this.ops.push({ command: "set", path: `/body/tbl[${n}]`, props: { "border.all": "none" } });
      for (let ci = 1; ci <= cols; ci++) {
        this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${headerRow}]/tc[${ci}]`, props: { "border.top": "single;12;000000", "border.bottom": "single;6;000000" } });
        this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${totalRows}]/tc[${ci}]`, props: { "border.bottom": "single;12;000000" } });
      }
    }
    // 表题行/表头行跨页重复 + 行不拆页
    for (let ri = 1; ri <= totalRows; ri++) {
      const rowProps: Props = { cantSplit: true };
      if (ri <= headerRow) rowProps.header = true;
      this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri}]`, props: rowProps });
    }
    // 整表不拆页：除最后一行外，所有单元格段落设置 keepNext
    if (opts.keepTogether !== false) {
      for (let ri = 1; ri < totalRows; ri++) {
        const cells = ri === 1 && hasCaption ? 1 : cols;
        for (let ci = 1; ci <= cells; ci++) {
          this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri}]/tc[${ci}]/p[1]`, props: { keepNext: true } });
        }
      }
    }
    // 单元格字体与对齐（跳过表题行）
    allRows.forEach((_, ri) => {
      if (hasCaption && ri === 0) return;
      const isHeader = ri === headerRow - 1;
      for (let ci = 1; ci <= cols; ci++) {
        // 「—」表示“无”的占位单元格一律居中，避免在左对齐列里贴着格线
        const v = (allRows[ri]?.[ci - 1] ?? "").trim();
        const align: "center" | "left" = v === "—" || v === "－" || v === "-" ? "center" : (aligns?.[ci - 1] ?? "center");
        const props: Props = { size, align, valign: "center" };
        if (isHeader) props.bold = true;
        this.ops.push({ command: "set", path: `/body/tbl[${n}]/tr[${ri + 1}]/tc[${ci}]`, props });
      }
    });
    return `/body/tbl[${n}]`;
  }

  /** 插入图片到指定段落 */
  picture(paraPath: string, src: string, widthCm: string, alt = "") {
    this.ops.push({ command: "add", parent: paraPath, type: "picture", props: { src, width: widthCm, alt } });
  }

  /** 图片段落（居中，图片宽度可调；与图题保持同页） */
  figure(src: string, widthCm: string, alt = "") {
    const p = this.para("", { align: "center", spaceBefore: "12pt", spaceAfter: "0pt", keepNext: true, firstLineIndent: "0pt" });
    this.picture(p, src, widthCm, alt);
    return p;
  }
}

/** 生成文档：rm + create + batch */
export function build(file: string, doc: Doc, opts: { quiet?: boolean } = {}) {
  // 批处理脚手架文件统一放在 .work 目录，保持交付目录干净
  const batchFile = path.join(__dirname, `${path.basename(file)}.batch.json`);
  fs.writeFileSync(batchFile, JSON.stringify(doc.ops, null, 1), "utf8");
  try { execFileSync("officecli", ["close", file], { stdio: "ignore" }); } catch { /* 无 resident 时忽略 */ }
  try { fs.rmSync(file, { force: true }); } catch { /* ignore */ }
  const create = execFileSync("officecli", ["create", file], { encoding: "utf8" });
  const out = execFileSync("officecli", ["batch", file, "--input", batchFile, "--json", "--best-effort"], { encoding: "utf8", maxBuffer: 128 * 1024 * 1024 });
  try { execFileSync("officecli", ["close", file], { stdio: "ignore" }); } catch { /* 忽略 */ }
  fs.writeFileSync(`${batchFile}.result.json`, out, "utf8");
  const res = JSON.parse(out);
  const items: any[] = res?.data?.results ?? res?.data?.items ?? res?.items ?? [];
  const failed = items.filter((i) => i && (i.success === false || i.status === "failed"));
  if (!opts.quiet) {
    console.log(`[build] ${file}: ${items.length} ops, ${failed.length} failed`);
    for (const f of failed.slice(0, 20)) console.log("  FAIL:", JSON.stringify(f).slice(0, 300));
  }
  return { failed, items, create };
}
