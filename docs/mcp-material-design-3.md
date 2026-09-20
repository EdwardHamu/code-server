# Material Design 3 界面改版

`lite/public/index.html` 与 `lite/public/style.css` 改为 Material Design 3（深色）风格。`lite/public/app.js` 未改动。

## 硬约束

改版必须在以下既有约束内完成，它们直接决定了实现方式。

| 约束 | 来源 | 后果 |
| --- | --- | --- |
| `default-src 'none'; style-src 'self'` | `lite/server.mjs:80` | 不能引 Google Fonts、Material Symbols 或任何 CDN；不能用行内 `style` 属性 |
| 仅路由 `/`、`/app.js`、`/style.css` | `lite/server.mjs:89` | 不能新增静态文件，图标必须内联 |
| 打包只复制这三个文件 | `ci/build-ubuntu-package.sh:54` | 同上 |
| `#code` / `#colored` / `#gutter` 三层重叠 | `lite/public/app.js` 的 `render()` | 三者字体度量必须逐像素一致，否则高亮错位 |

因此：MD3 令牌全部手写为 CSS 自定义属性，图标为文档内联的 SVG `<symbol>`，字体沿用系统 UI 栈。

## 改动内容

### 设计令牌

以原有的青色强调色为源色，扩展成完整的 MD3 色调板：

- 颜色角色：`--md-primary`、`--md-on-primary`、`--md-primary-container` 等；错误色走 `--md-error` 系列。
- 表面层级：`--md-surface-c-lowest` 到 `--md-surface-c-highest` 五级，用色调区分层次，取代原来的描边分隔。
- 形状：`--md-shape-xs` 至 `--md-shape-full`。
- 状态层不透明度：hover 8%、focus 10%、press 10%，与 MD3 规范一致。
- 动效：`--md-ease-emphasised` 等缓动曲线与时长。

### 组件

- **按钮**：统一基础配方，用 `::before` 伪元素做状态层。派生 filled（`.primary`）、text（`.tool-button`）、icon（`.icon-button`）、destructive（`.danger`）四种变体。触摸目标不小于 32–36px。
- **文本框**：MD3 filled 样式，色调容器 + 底部指示线，聚焦时加粗为 2px 并补偿内边距以防跳动。
- **标签页**：活动指示条从中心向两侧展开，使用强调缓动。
- **侧栏与工作区**：改为圆角容器卡片，靠表面色调而非描边分层。
- **Git 变更项**：由分隔线列表改为 filled 卡片，状态码呈现为 pill 徽章。
- **登录框**：MD3 dialog，28px 圆角、5 级阴影、入场动画。
- **图标**：16 个内联 SVG symbol，`stroke: currentColor`，随按钮状态变色。

### 可访问性

- 焦点环统一为 `2px` 外描边加 `2px` 偏移。
- 图标按钮补充 `aria-label`。
- 新增 `prefers-reduced-motion` 支持。
- 原 HTML 中的 3 处行内 `style` 属性（被 CSP 拦截、实际失效）改为 CSS 类。

## 兼容性

- 原有 DOM 的 **id 与 class 全部保留**，无一删除；新增仅为 16 个图标 symbol 的 id。`app.js` 依赖的 `.tree-button`、`.selected`、`.change`、`.status`、`.path`、`.tree-node`、`.plain`、`.error`、`.active` 均未变动。
- `#gutter` / `#code` / `#colored` 保持共享的 `13px/21px` 等宽字体与 `tab-size: 2`，高亮对齐不受影响。
- `lite/check.mjs` 通过。
- `npm test`：22 项中 21 项通过、0 项失败，1 项为 POSIX 专属用例在 Windows 上跳过。
- `npm run test:browser` 在当前环境因无法启动无头 Edge/Chromium 而超时，属环境限制，与本次改动无关；建议在有浏览器的环境中复跑。
