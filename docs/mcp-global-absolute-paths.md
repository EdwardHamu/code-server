# 服务器绝对路径支持

## 行为与范围

- 新建文件/目录的网页输入要求服务器绝对路径，并预填当前浏览目录。
- 文件浏览增加绝对目录输入、回车/按钮跳转和上级目录；新建成功后显示目标父目录。
- 文件 API 支持当前操作系统的全局绝对路径。Linux 使用 `/`，Windows 支持盘符路径及跨盘输入；旧相对 API 路径仍以启动 `--root` 为基准。
- 列表、读取和新建结果返回绝对路径。浏览失败保留原文件树，切换浏览目录不清空编辑缓冲。
- `--root` 是初始目录与固定 Git 仓库，不再是文件访问边界。Git 相对路径校验未放宽。

## 安全与限制

- 登录用户可访问服务进程账户有权限的项目外普通文件；部署者应明确授予目录权限，仅供可信用户使用，不建议 root/管理员运行。
- 不提权、不更改系统权限，不改变认证、Origin/CSRF 校验、版本冲突保护、体积/行数限制和按需加载方式。
- 父目录必须存在；不递归创建父目录、不递归删除目录。
- 仍拒绝路径穿越、`.git`、符号链接/junction、硬链接、Windows UNC/设备路径、ADS 和特殊文件编辑。
- 容器挂载、服务沙箱和账户权限仍可能限制可见范围；本次没有修改部署权限或重启现有服务。

## 修改位置

- `lite/files.mjs`：服务器路径解析、逐段链接检查、绝对路径响应。
- `lite/server.mjs`：会话返回初始绝对目录与服务器路径类型。
- `lite/public/app.js`、`lite/public/index.html`：目录导航与绝对路径新建交互。
- `lite/test/core.test.mjs`：项目外 CRUD、根目录、路径语法与保护回归。
- `lite/browser-smoke.mjs`：真实浏览器项目外导航、新建、保存与失败保留状态检查。
- `README.md`：使用方式与权限边界。

## 验证

- 远程 Windows 工作区：`npm run build` 通过；`npm test` 共 21 项，20 通过、1 项 POSIX 权限位测试按平台跳过，0 失败。
- 远程 Edge：`npm run test:browser` 通过，包括绝对目录导航、项目外文件/目录创建与保存、失败导航保留文件树、上级导航保留编辑缓冲；无未捕获异常。测试临时替换 prompt 返回值，不验证原生对话框的手动键入。
- 本地 Linux 副本（Node.js 20.20.2，辅助跨平台验证，不替代项目要求的 Node.js 24）：21/21 测试通过，包括 POSIX 权限位保存。
- `get_diagnostics` 的 `lite` 范围错误/警告为 0；`git diff --check` 通过。
- 所有写入测试均使用临时夹具，没有对生产目录执行试写，没有部署、提交或推送本项目。

## 生产部署（2026-09-19）

- 通过本机 `ssh vultr` 在 Ubuntu 18.10 主机安装 `code-server_0.1.1-1_amd64.deb`（sha256 `4a6cadccab3693506937a7d5e6e888f40aaf9a3aef1cdb79bdee7c3ee3e781e8`），从 `0.1.0+lite.1-1` 升级；包内含 `fileTarget`/`open-directory` 新功能，捆绑 Node 24.12.0。
- `systemctl restart code-server-lite` 后服务 active、NRestarts=0；`http://127.0.0.1:8444/vscode/` 与 `https://meamoe.top/vscode/` 均返回 200，页面已包含新目录导航。
- 安装包备份在服务器 `/root/code-server_0.1.1-1_amd64.deb`。未修改 systemd 单元、nginx、密码或工作区权限。
- 原单元 `User=code-lite`、`ProtectSystem=strict`、`ProtectHome=true`、`ReadWritePaths=/srv/code-workspace /var/lib/code-server-lite`，项目外路径多数只读。
- 经用户确认改为完全 root、无沙箱：`User=root`、`HOME=/root`、`UMask=0022`，移除 ProtectSystem/ProtectHome/ReadWritePaths/NoNewPrivileges/PrivateTmp。原单元备份为 `/etc/systemd/system/code-server-lite.service.bak-20260919131533`。重启后 active、进程以 root 运行、公网 200。
- 安全影响：网页密码等同于服务器 root 文件读写权限；Git filter/凭据助手/SSH 以 root 执行。建议使用强密码并限制访问来源。

## 目录持久化与历史记录

- 新增 `lite/state.mjs`：保存 `lastDirectory` 与 `recentDirectories`（最多 30 条，最近优先，含 `openedAt`），JSON 文件权限 0600，临时文件加 rename 原子写入，写入串行化。
- 记录触发：`GET /api/files?remember=1`，前端仅在“打开目录/上级目录/历史选择/新建后定位/刷新”调用；树内展开子目录不记录。列表失败（404/403）不记录。
- `GET /api/session` 返回历史与上次目录；登录后自动回到上次目录，不可用时回退初始目录并提示。`GET/POST /api/recent` 支持 `forget`/`clear`，POST 受 CSRF 校验。
- 状态文件默认 `$CODE_SERVER_LITE_HOME|$HOME|$USERPROFILE/.code-server-lite/state.json`，`--state-file /绝对路径` 覆盖，`--state-file none` 关闭（仅内存）。
- 前端新增历史目录下拉、“移除此历史”“清空历史”。
- 验证：Windows `npm test` 22 项 21 通过 1 跳过；Edge `npm run test:browser` 通过（含历史选择/移除与服务器持久化文件核对）；Linux 副本 22/22；`git diff --check` 通过。
- 生产服务器（root 单元，`HOME=/root`）安装新版本后状态文件将写到 `/root/.code-server-lite/state.json`，无需改单元；旧 code-lite 单元需保证 HOME 可写或加 `--state-file`。
