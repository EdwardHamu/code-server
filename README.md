# code-server lite

本分支默认运行**极简文件编辑器 + Git 管理**，不再启动 VS Code。
目标是低常驻内存，而不是保持 VS Code 扩展兼容性。

## 保留

- 按需展开的文件树；创建目录、创建/删除文件。
- 单文件 UTF-8 编辑、基本词法高亮、查找/替换、快捷键保存。
- SHA-256 版本校验防止静默覆盖外部修改；同目录临时文件写入后替换。
- Git 状态、工作区/暂存区差异、暂存/取消暂存、提交、新建/切换分支、fetch、快进 pull、push。
- 密码登录、有限期会话、CSRF/Origin 校验、HTTPS 反向代理部署。

## 不再加载

VS Code / Monaco、扩展宿主、语言服务、终端、调试器、任务执行器、全局搜索索引、文件监视器、插件市场、端口代理、遥测、自动更新。

运行时与开发依赖均为 **0**。只有一个 Node 服务进程，Git 在用户操作时短暂运行。

## 启动

需要 **Node.js 24** 和 Git。无需 `npm install`，也无需下载 `lib/vscode`。

```bash
# 不把密码写入命令历史；至少 12 个字符。
read -rs -p 'Workspace password: ' PASSWORD; echo
export PASSWORD
node lite/server.mjs --root /absolute/path/to/project
```

本机访问 `http://127.0.0.1:8080/`。`--root` 设置初始浏览目录和 Git 管理仓库，不再作为文件访问边界；非仓库仍能浏览编辑文件。
也可用 `npm start -- --root /absolute/path/to/project`。

## 服务器绝对路径

- 新建文件/目录填写服务器绝对路径，例如 Linux `/srv/data/notes.txt`、Windows `D:\data\notes.txt`，父目录须已存在。
- 文件面板可输入绝对目录路径并点击“打开目录”（或回车），通过“上级目录”浏览项目外目录；Windows 可输入其他盘符切换磁盘。
- 通过“打开目录/上级目录/历史目录”进入的目录会记录到服务器端历史（最多 30 条，按最近打开排序），重启服务和重新登录后自动回到上次目录；树内展开子目录不计入历史。可单条移除或清空。历史文件默认 `~/.code-server-lite/state.json`（服务账户 HOME），可用 `--state-file /绝对路径` 指定或 `--state-file none` 关闭；权限 0600，原子写入。
- 新建后自动显示目标父目录；文件列表、打开、保存、删除均支持绝对路径。旧 API 相对路径仍以 `--root` 为基准兼容。
- 访问范围由服务进程账户的操作系统权限决定。无权限时返回 403，不自动提权或修改权限；容器内只能访问容器可见/挂载路径。
- 不支持 UNC/设备路径，仍拒绝 `.git`、符号链接/junction、硬链接和特殊文件编辑；这不是无条件访问所有路径。
- **登录用户可以读写该账户有权限的项目外普通文件。** 仅供可信用户使用，避免 root/管理员运行。Git 操作始终绑定 `--root`，不随文件浏览目录切换。

## 远程访问必须经过 HTTPS

```bash
node lite/server.mjs --root /srv/projects/my-project \
  --host 127.0.0.1 --port 8080 \
  --origin https://editor.example.com --secure-cookie
```

Caddy 配置：

```caddyfile
editor.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

- 为自己的域名配置 DNS 与有效 TLS；不要将 HTTP 后端端口直接暴露到公网。
- `--origin` 是浏览器访问的精确源，不含路径或结尾斜杠。
- 子路径可加 `--base-path /code`，访问 `/code/`；代理必须保留 `/code` 前缀，不要 strip prefix。
- 跨主机/容器代理需要非 loopback 监听时，必须同时提供 HTTPS origin 和 secure cookie，并由网络规则限制后端访问。
- 生产环境用独立账户，按需授予要管理的服务器目录权限；通过受保护的服务环境文件设置 PASSWORD，不使用 root 运行。

## 验证与交付

```bash
npm run build       # 仅语法检查，没有 VS Code 构建
npm test            # 真实 HTTP + 临时 Git 仓库测试，不访问公网
npm run measure     # 独立子进程的内存采样
npm run test:browser # Edge/Chromium 真浏览器检查；可用 BROWSER 指定可执行文件
npm pack --ignore-scripts
```

npm 包仅包含 `lite/` 必要运行文件、此 README、任务报告和 LICENSE，不包含旧 VS Code 源码、补丁、测试及依赖目录。解包后直接 `node lite/server.mjs`，或安装生成的本地 tgz 使用 `code-server` 命令。

## Ubuntu 18.10 安装包

只生成 Ubuntu 18.10 amd64 的 `.deb` / `.tar.gz` 并上传 GitHub Release。工作区必须干净；脚本只推送已有提交，然后触发并监控 `.github/workflows/release-ubuntu.yml`，结束后弹窗：

```bash
bash scripts/release-ubuntu.sh --tag v0.1.0-lite.1
```

说明、限制和离线测试见 [docs/mcp-ubuntu-release.md](docs/mcp-ubuntu-release.md)。

## 有意限制

- 单用户、固定 Git 仓库、全局文件浏览、单编辑缓冲；文本文件上限 1 MiB / 20,000 行，仅 UTF-8。二进制和其他编码不编辑。
- 普通文件保存保留 UTF-8 BOM 与 LF/CRLF 类型；混合换行会统一为检测到的换行类型。保存只保留权限位，不保证 ACL、扩展属性、文件所有者保持不变。
- 高亮与行号仅渲染可见行；超过 128,000 字符、10,000 行或单行超过 4,000 字符时关闭高亮；每目录最多列出 1,000 项，Git 变更最多显示 1,000 项，Git 输出上限 2 MiB。
- Git 使用服务器已有仓库、远端和非交互凭据；不提供终端、仓库初始化/克隆、远端配置、冲突合并界面、强制推送、递归删除或任意 Git 命令输入。
- Git 常规 hooks、外部 diff/textconv、提交签名、fsmonitor 被关闭。仓库过滤器、凭据助手和 SSH 仍可能执行服务器上的程序；**这不是不可信仓库的进程沙箱**。
- 拒绝直接访问 `.git`、符号链接/junction、硬链接和不安全路径。防护针对网络输入；不保证抵御同时改写文件系统的恶意本地进程。
- 登录空闲 30 分钟过期，绝对期限 8 小时；过期后重新登录，页面未保存缓冲仍保留。重启不保留会话。
- 不兼容上游 YAML 配置、HASHED_PASSWORD、VS Code CLI 参数和旧安装器。原安装器已归档到 `ci/legacy-install.sh`；根目录 `install.sh` 只给出迁移提示，不下载上游完整版。

旧 `src/`、`patches/`、`test/` 和上游文档保留为迁移参考，不被当前入口加载，也不打入轻量包。旧工作流已移到 `ci/legacy-workflows/`，当前 CI 仅检查轻量版，不自动发布。

架构、测量结果和迁移范围见 [任务报告](docs/mcp-lite-editor.md)。
