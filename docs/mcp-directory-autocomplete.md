# 目录路径输入子目录自动补全

## 功能

- 在“服务器绝对路径”输入框输入时，自动列出所输入父目录下、以当前末段为前缀的子目录（仅目录，最多 50 条，超出显示提示）。
- 键盘：↑/↓ 选择，Enter 打开高亮项，Tab 仅补全路径不跳转，Esc 关闭；未高亮时 Enter 仍为原“打开目录”行为。鼠标点击项直接打开。
- 输入防抖 120 ms；同一父目录列表缓存，切换前缀不重复请求；失焦后关闭；非绝对路径或无匹配时不显示。
- 建议列表使用 `GET /api/files` 只读读取，**不带 `remember=1`，不写入目录历史**；只有实际打开才记录。
- ARIA：输入框 `role=combobox` + `aria-expanded`，列表 `role=listbox/option`，高亮项 `aria-selected`。

## 修改

- `lite/public/index.html`：路径输入外层加 `.path-field`，新增 `<ul id="directory-suggest">`。
- `lite/public/style.css`：MD3 配色的下拉样式（surface-container-high / primary-container 高亮）。
- `lite/public/app.js`：`suggest` 模块（split/render/highlight/choose/update）；`browseDirectory()` 打开前关闭下拉。
- `lite/browser-smoke.mjs`：新增建议列表过滤、键盘选择打开、无匹配关闭的真实浏览器检查。

## 验证

- `npm run build` 通过；`npm test` 22 项 21 通过 1 跳过（后端未改）；`git diff --check` 通过。
- **远程 Windows `npm run test:browser` 本次无法运行**：Edge 无头启动超时（`Browser startup timeout`），对改动前的原始文件同样超时，属于本机 Edge/环境问题而非本改动；本机已存在 3 个残留 `lite-browser-*` 临时 profile。
- 作为替代，在 Linux 侧用 jsdom 驱动真实 `index.html + app.js` 完成交互测试：前缀过滤仅目录、↑/↓ 高亮、Enter 打开并关闭、Tab 只补全、Esc/无匹配/相对路径关闭、无高亮 Enter 走原逻辑、建议请求不记录历史。全部通过（脚本在会话侧，未提交到仓库）。
- Windows Edge 恢复后请运行 `npm run test:browser` 复核；期间清理 `%TEMP%\lite-browser-*`。未提交。
