/**
 * 本项目文档后端：只走 officecli 生成 .docx（不含 LaTeX 后端）
 * 内容脚本通过 createDoc()/finish() 使用，与课程工具链接口一致
 */
import { Doc, build } from "./offi";

export function createDoc(opts: { titlePage?: boolean; footer?: boolean } = {}): Doc {
  const d = new Doc();
  d.bootstrap(opts);
  return d;
}

export function finish(docxPath: string, d: Doc) {
  const res = build(docxPath, d);
  process.exit(res.failed.length ? 1 : 0);
}
