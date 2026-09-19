# code-server 极简低内存改造

日期：2026-09-19
项目：`E:/Code/pj/code-server`

## 1. 目标与用户确认

用户明确选择：**极简低内存**、**远程浏览器访问**。
因此允许替换 VS Code 内核、删除扩展/语言服务/终端/调试等能力，但必须保留文件浏览编辑、基本 Git 管理与远程登录防护。

本轮改变的是默认入口和分发方式，不是仅在旧 VS Code 界面隐藏按钮。

## 2. 旧架构与基线限制

- 原 `src/node/entry.ts` 经过 wrapper 启动完整 code-server / VS Code 服务；原 package.json 存在 VS Code 构建、postinstall、开发 watch 等路径。
- 原根清单直接声明 20 个运行依赖、28 个开发依赖；新默认实现均为 0。
- 检查时工作区干净，未发现 AGENTS.md；`lib/vscode` 是空目录，未安装原项目依赖，也没有可直接运行的原版 VS Code 构建。
- **没有原版在相同环境下的实测 RAM 基线，因此不提供“比原版省了百分之多少内存”的结论。** 不把磁盘体积、JS 堆或 DOM 数量当作整个应用的物理内存。

## 3. 新架构

| 部分 | 文件 | 作用 |
| --- | --- | --- |
| HTTP / 鉴权 / CLI | `lite/server.mjs` | 单 Node 进程；静态资源、会话、CSRF/Origin、API 路由和并发上限 |
| 文件访问 | `lite/files.mjs` | 路径校验、惰性目录枚举、UTF-8 读写、版本校验及文件创建/删除 |
| Git | `lite/git.mjs` | 固定动作白名单；spawn 参数数组，不使用 shell；用户操作时才运行 Git |
| 浏览器 | `lite/public/` | 无框架、无 CDN、原生单文件编辑、可见行词法高亮和行号 |
| 核心回归 | `lite/test/core.test.mjs` | 真实本地 HTTP、文件系统、临时 Git 仓库与本地 bare remote |
| 浏览器检查 | `lite/browser-smoke.mjs` | 通过 CDP 驱动已安装 Edge/Chromium，无自动浏览器下载 |
| 内存采样 | `lite/measure.mjs` | 独立新服务进程，采样 RSS / heapUsed；父进程负责请求，不混入测试运行器内存 |

默认 `npm start` 与 `code-server` bin 均指向轻量入口。不再加载 VS Code / Monaco、扩展宿主、语言服务器、终端、调试器、任务系统、文件监视器、索引、市场、遥测、更新器或端口代理。

## 4. 保留的功能

- 按需文件树；展开才请求该目录，折叠移除子树 DOM；手动刷新，不周期扫描仓库。
- 新建目录、新建文本文件、打开、编辑、保存和删除普通文件。
- 单编辑缓冲、Ctrl/Cmd+S、基本高亮、查找/替换、原生编辑/撤销；未保存离开提示。
- 保存时校验原始字节的 SHA-256；过期版本返回 409，不静默覆盖。
- 同目录独占临时文件写入、sync、保留权限位、再次核对版本后 rename；失败清理临时文件。
- Git 状态、工作区和暂存区差异、暂存/取消暂存、提交、新建/切换本地分支、fetch、仅快进 pull、普通 push。
- 不自动提交、不自动推送；远端变更与提交等动作由用户明确点击确认。测试中的提交/推送仅发生在临时测试仓库。
- Git 使用服务器原有身份及非交互凭据，不向浏览器提供任意命令执行接口。

## 5. 内存控制与资源边界

- 文件最大 1 MiB / 20,000 行；二进制、无效 UTF-8 拒绝编辑。行数限制避免许多空行造成原生 textarea 内部节点膨胀。
- 高亮和行号只生成视口附近的节点，滚动通过 requestAnimationFrame 合并更新；不为整个文件产生高亮 DOM。
- 超过 128,000 字符、10,000 行或单行 4,000 字符时退回纯文本显示。高亮只是轻量词法着色，不提供完整语义分析，跨视口多行结构可能着色不准确。
- 每目录最多 1,000 项；不递归预读。Git 状态最多显示 1,000 项、分支最多 1,000 项，Git 标准输出/错误合计限制 2 MiB，差异界面最多渲染 256,000 字符。
- 普通 Git 操作超时 20 秒，网络 Git 操作 60 秒；超时尝试终止其进程树。
- 工作区写操作与 Git 操作串行，避免保存/切分支互相覆盖；HTTP 活跃处理最多 4 个、连接最多 32 个。
- 登录验证同一时刻仅 1 次；会话最多 64 个，失败来源记录最多 512 项；一分钟清理一次过期记录。
- 没有后台 Git 网络轮询、后台索引、自动保存或扩展 worker。

## 6. 远程访问安全与边界

- PASSWORD 环境变量必须为 12–1024 字符，不接受明文密码 CLI 参数；启动后从子进程继承环境中移除 PASSWORD。
- scrypt 验证，随机高熵会话令牌、HttpOnly / SameSite=Strict Cookie，可启用 Secure；空闲 30 分钟、绝对 8 小时过期。
- 每来源 5 次 / 5 分钟密码尝试；POST 必须 JSON，校验精确 Origin，已登录写操作还需 CSRF Token；不信任任意 X-Forwarded-*。
- 默认仅监听 loopback；非 loopback 启动必须配置 HTTPS origin 和 Secure Cookie。HTTPS 在 Caddy/Nginx 等代理终止，后端仍是 HTTP，必须限制后端端口的网络访问。
- 静态 HTML 不含用户文件；文件和 Git API 必须登录。限制 CSP、禁止嵌入、禁止 MIME sniff、响应不缓存。
- 拒绝路径穿越、绝对路径、Windows ADS/危险名称、直接访问 `.git`、符号链接/junction、硬链接和工作区外路径。
- Git 不自动发现父仓库，不接受外部 gitdir 或 linked worktree；根目录必须匹配当前仓库。
- 关闭常规 Git hooks、fsmonitor、外部 diff/textconv 及提交签名；但 Git 配置里的过滤器、凭据助手或 SSH 仍可运行程序。**仅供受信任的单用户仓库，不是执行沙箱。**
- 路径检查不保证抵御能并发替换文件系统节点的恶意本地进程。请使用隔离的低权限 OS 账户/容器，不授予其他不可信本地用户写入该工作区的权限。
- 保存保留 BOM 和 LF/CRLF 类型；混合换行会统一。不保证保留 ACL、扩展属性或原文件所有者。没有递归删除、强制推送、强制覆盖或任意命令入口。

## 7. 实测结果

### Windows 服务进程

Node v24.12.0。启动一个独立的新进程，GC 后记录空闲状态；随后登录、读取 103,500 字节文件 20 次、真实 Git status 20 次，再 GC 采样。

| 指标 | 初始空闲 | 完成上述操作后 |
| --- | ---: | ---: |
| Node RSS | 64,823,296 B（61.82 MiB） | 68,526,080 B（65.35 MiB） |
| Node heapUsed | 7,184,224 B（6.85 MiB） | 8,097,872 B（7.72 MiB） |

RSS 不包括浏览器，也不包括已经退出的瞬时 Git/凭据/SSH 子进程；该采样不是压力峰值或长期稳定性证明。密码验证仍会短暂使用 scrypt 内存。

### Windows Edge 浏览器

实际浏览器完成登录、文件树、原生输入、Ctrl+S 保存到磁盘、转义高亮、反复切换 103,500 字节文件、视口行号和 Git 状态检查。无捕获到的未处理 JS 异常。

- 最初的全量高亮原型：重复切换后 36,220 个 CDP Nodes。
- 改为可见行高亮后的最终复测：9,420 个 CDP Nodes；JSHeapUsedSize 为 758,144 B，约 0.72 MiB。高亮 span 少于 1,000；剩余节点主要来自 4,500 行原生 textarea 内部结构，不是全文件高亮 DOM。
- 该比较仅是**本轮轻量原型内部优化**，不是与原 VS Code 比较。原生编辑控件等仍有内部节点；DOM 节点数量下降不等价于整体 RAM 下降。
- 最终复测原始输出保存在 `artifacts/lite-browser.json`，示例截图为 `artifacts/lite-editor.png`；均为合成测试工作区，不含用户项目内容。

### 测试记录

- Windows Node 24：19 项核心用例，18 通过、1 项 POSIX 执行权限测试按平台跳过，0 失败。
- Arena Linux Node 20.20.2 补充验证：同一套 19/19 通过，含权限测试。正式声明的目标运行版本仍为 Node 24；Linux Node 24 的 GitHub CI 尚未实际触发。
- Windows `npm ci --offline --ignore-scripts --no-audit --no-fund` 通过，无依赖下载；语法检查通过。
- 包清单已验证为运行文件白名单，不含上游 VS Code、旧测试和依赖树。
- 核心测试使用实际 HTTP、实际 Git 与本地 bare remote 验证 fetch/pull/push，并非仅 mock；未访问 GitHub 或生产服务器。
- 浏览器测试和 Node 数据只代表指定合成场景；尚未验证公网 TLS、真实 GitHub/SSH 凭据、大仓库长期运行或多用户隔离。

## 8. 默认入口与迁移

参见根目录 `README.md` 的启动和 Caddy 配置。

```bash
read -rs -p 'Workspace password: ' PASSWORD; echo
export PASSWORD
node lite/server.mjs --root /srv/projects/my-project \
  --host 127.0.0.1 --port 8080 \
  --origin https://editor.example.com --secure-cookie
```

- 先使用独立端口、已有可信仓库进行验证，再手动切换自己的反向代理或服务启动命令。本轮没有替用户部署或停止现有生产服务。
- 新版不读取旧 code-server YAML、HASHED_PASSWORD、VS Code CLI 参数或扩展目录；不支持 VS Code 插件兼容。
- 旧工作流归档到 `ci/legacy-workflows/`，不再执行原构建、上游更新和发布路径；新增 `.github/workflows/lite.yml`，在 Windows/Linux Node 24 检查和打包，不自动发布。
- Ubuntu 18.10 amd64 安装包由 `.github/workflows/release-ubuntu.yml` 手动触发；见 `docs/mcp-ubuntu-release.md`。
- 原安装器归档到 `ci/legacy-install.sh`；根 `install.sh` 仅给出迁移提示并拒绝原安装流程，防止误装完整版。
- 旧 `src/`、`patches/`、`test/` 和上游文档留作参考，**未物理删除全部历史源码**；它们不在默认运行链路或轻量 npm 包中，不产生运行时内存开销。
- 如以后需要恢复完整 VS Code，应恢复这次变更前的版本及其依赖/构建，而不是在轻量入口混用旧参数。

## 9. 后续建议

- 部署前备份仓库，尤其是未提交文件；校验目标账户权限和 Git 非交互认证。
- 使用真实仓库评估文件大小/行数限制是否适合工作流，再决定是否放宽；不要无上限加载目录、差异或文件。
- 若需要多用户、终端、复杂补全、冲突合并 UI 或大型文件虚拟编辑，应作为新的取舍任务，不静默重新引入完整 VS Code。

当前范围：源码、测试、文档、入口和 CI 调整。**没有提交、推送、发布或生产部署。**
