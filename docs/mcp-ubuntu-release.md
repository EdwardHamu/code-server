# Ubuntu 18.10 安装包发布

日期：2026-09-19
项目：`E:/Code/pj/code-server`

## 1. 需求

- 新增 `.github/workflows/release-ubuntu.yml`，只打 Ubuntu 安装包并上传。
- 目标系统：**Ubuntu 18.10 (cosmic) amd64**。
- 编写 sh：推送已有提交，用 `gh` 触发工作流，持续监控，完成后弹窗；所有网络请求带重试。
- 按既有约束：**只推送已有提交**；工作区有未提交改动则停止；不自动提交、不强推、不取消云端任务。

用户原文写的是触发 `release-win.yml`。本仓库没有该工作流。对应文件是新建的 `release-ubuntu.yml`，脚本 `scripts/release-ubuntu.sh` 触发并监控它。

## 2. 为什么 GitHub 不能 “跑在 18.10 上打包”

GitHub 托管 runner 没有 Ubuntu 18.10。`actions/checkout` 等也需要比 cosmic 更新的 glibc。

因此作业跑在 **ubuntu-22.04**，生成的是 **给 18.10 用的 amd64 包**：

- `.deb` 声明 `Depends: libc6 (>= 2.28)`（18.10 的 glibc 正是 2.28）。
- 内置官方 Node.js 24 linux-x64。Node 文档的 Linux 下限是 **glibc 2.28、kernel 4.18**，与 18.10 对齐。
- 不依赖 18.10 软件源里的 nodejs（该发行版已于 2019-07 停止支持）。

这不是在 18.10 虚拟机里执行 `dpkg-buildpackage`。未拉取已归档的 `ubuntu:18.10` 容器做运行时冒烟。

## 3. 产物

`ci/build-ubuntu-package.sh` 生成：

- `code-server_<debian-version>_amd64.deb`
- `code-server-<tag>-ubuntu18.10-amd64.tar.gz`
- `SHA256SUMS`

包内只有 lite 运行文件和 Node 可执行文件，不含 `src/`、`patches/`、测试或 VS Code。主机还需要 `git`。

标签 `v0.1.0-lite.1` 对应 Debian 版本 `0.1.0+lite.1-1`（避免把最后一个连字符误当成 Debian revision）。

## 4. 触发与监控

```bash
# 工作区必须干净。只推当前分支已有提交，然后触发并监控。
bash scripts/release-ubuntu.sh --tag v0.1.0-lite.1
```

其它用法见脚本 `--help`。`--allow-remote` 只构建远端、不推送。`--run-id` / `--request-id` 只恢复监控，不重新触发。`--notify-test` 只测弹窗。监控到 `success` 后默认继续把该次运行的产物部署到服务器（`--no-deploy` 关闭），细节见 [docs/mcp-release-ubuntu-autodeploy.md](mcp-release-ubuntu-autodeploy.md)。

网络：`gh`/`git push` 经 GNU `timeout` 与指数退避重试（默认 5 次，上限 30 秒）。触发前先查 run list，避免重复 dispatch。监控超时或 Ctrl+C **不取消** 云端作业。

完成、失败、取消、超时或脚本异常都会尝试弹窗：Windows 用 `WScript.Shell.Popup`，否则 `osascript` / `notify-send`，再否则响铃并写终端。

工作流必须已在 **默认分支** 上，`gh workflow run` 才能找到它。

## 5. 验证

- `bash scripts/test-release-ubuntu.sh`：31 项离线用例（假 gh/git/ssh/scp/通知），含自动部署的成功与失败分支以及 `DEPLOY_DRY_RUN`。不访问 GitHub，不连服务器，不弹真窗。
- `bash ci/test-build-ubuntu-package.sh`：需要 `dpkg-deb`。假 Node 压缩包、curl 前两次失败后成功、校验 control 含 Ubuntu 18.10 与 libc6 >= 2.28、拒绝把 `src/` 打进包。
- 未对真实 GitHub 执行 push、workflow_dispatch 或创建 Release。

## 5.1 上传步骤 404 静默失败

`gh api` 在 Release 不存在时返回 HTTP 404 且退出码非 0。原先内联步骤使用 `set -euo pipefail`，并把查询放在管道/`$()` 里，404 会立刻让整个 step 失败；stderr 被丢到 `/dev/null`，Actions 只显示 exit code 1。

现改为 `ci/publish-ubuntu-release.sh`：用 `set +e` 读响应头，**404 表示可以创建**，200 拒绝覆盖，其它状态重试。已用离线用例复现旧行为并锁定新行为。
- 未在真实 Ubuntu 18.10 机器上安装或启动该包。

## 6. 安全与范围

- 仅 `workflow_dispatch`。检出提交固定为传入的 `source_sha`。
- 已有同名 Release 则拒绝覆盖。
- 不自动写 git tag 以外的仓库内容；`gh release create --target SHA` 按该提交建标签。
- 脚本不读取密码、不打印 token。
- Node 压缩包必须有 SHA-256；下载源默认仅 `https://nodejs.org/dist`。

当前范围：工作流、打包脚本、触发监控脚本、离线测试和文档。**没有提交、推送或真实发版。**
