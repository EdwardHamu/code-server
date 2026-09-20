# 打包成功后自动部署到服务器

日期：2026-09-20
项目：`E:/Code/pj/code-server`

## 1. 需求

`scripts/release-ubuntu.sh` 检测到 `.github/workflows/release-ubuntu.yml` 的 `conclusion=success` 后，直接完成部署，不需要人工把 `.deb` 传到服务器。

## 2. 流程

监控确认成功后按顺序执行：

1. `gh api .../runs/<id>/artifacts` 只取**本次运行**的产物：
   - 名称必须以 `ubuntu-18.10-amd64-` 开头且未过期；
   - 缺失、过期或匹配到多个时直接失败（退出码 3），**不会**回退到 Release 里的最新文件；
   - 产物名里的标签必须与本次构建标签一致，否则拒绝部署。
2. `gh run download` 下载到本地临时目录，按产物内 `SHA256SUMS` 用 `sha256sum` 校验 `code-server_*_amd64.deb`。
3. 通过已有 SSH 别名（默认 `vultr`，可用 `--deploy-host` 或 `DEPLOY_SSH_HOST` 覆盖）：
   - `ssh <别名> mktemp -d /tmp/code-server-deploy.XXXXXXXX` 建立远端暂存目录；
   - `scp` 上传安装包。脚本不读取、不存储、不转发任何凭据，认证沿用用户自己的 SSH 配置。
4. 远端以内联 Bash 脚本执行（**只尝试一次**，避免“响应丢失但其实已安装”导致的重复安装）：
   - 校验参数、要求 root、`flock -n /run/lock/code-server-deploy.lock` 防止并发部署；
   - `sha256sum -c` 复校验上传文件；
   - `dpkg-deb -f` 校验包名、架构与版本：Debian 版本必须等于标签映射值（`v0.1.4` → `0.1.4-1`，`v0.1.0-lite.1` → `0.1.0+lite.1-1`，与 `ci/build-ubuntu-package.sh` 的规则一致）；
   - 解包后用新包自带的 `node --version` 做预检；
   - `tar` 备份 `/usr/lib/code-server`、`/usr/bin/code-server`、`/etc/code-server-lite`、systemd 单元与 dpkg 记录到 `/root/code-server-backup.XXXXXXXX`；
   - `dpkg --force-confold -i` 安装，保留服务器上的本地配置；
   - 重启 `code-server-lite.service`，最多 30 秒内轮询回环地址得到 200；
   - 校验 `dpkg-query` 版本，并确认公网地址返回 200。
   - 成功后删除远端暂存目录；失败时保留暂存目录并打印备份路径，**不自动回滚**。

## 3. 用法

```bash
# 默认：打包成功即自动部署
bash scripts/release-ubuntu.sh --tag v0.1.0-lite.1
# 只监控，不部署
bash scripts/release-ubuntu.sh --tag v0.1.0-lite.1 --no-deploy
# 对某次已成功的运行补做部署
bash scripts/release-ubuntu.sh --repo EdwardHamu/code-server --run-id 123456
# 演练整条链路：照常下载、校验、上传，远端只做只读预检后退出
DEPLOY_DRY_RUN=1 bash scripts/release-ubuntu.sh --repo EdwardHamu/code-server --run-id 123456
```

环境变量：`DEPLOY_SSH_HOST=vultr`、`DEPLOY_LOCAL_URL=http://127.0.0.1:8444/vscode/`、`DEPLOY_PUBLIC_URL=https://meamoe.top/vscode/`、`DEPLOY_TIMEOUT_SECONDS=300`、`DEPLOY_DRY_RUN=0`。

退出码：0 成功（含部署成功）、1 打包或配置错误、2 云端任务被取消、3 打包成功但部署失败、124 超时。

## 4. 失败与回滚

- 部署失败不影响云端构建：产物仍在运行页，可对同一次 `--run-id` 重跑命令重试。下载与校验是幂等的；安装步骤不做自动重试。
- 自动回滚未实现。需要还原时使用错误输出里的备份目录：

```bash
ssh vultr 'tar -xzf /root/code-server-backup.XXXXXXXX/program-config.tar.gz -C / && systemctl restart code-server-lite.service'
```

- 服务器保留版本：服务单元的 `Description` 仍写着旧字符串，判断版本以 `dpkg-query -W code-server` 为准。

## 5. 验证

- `bash scripts/test-release-ubuntu.sh`：31 项离线用例（假 `gh`/`git`/`ssh`/`scp`/通知），覆盖标签不匹配、产物过期或歧义、校验值缺失或不符、上传失败、远端安装失败、`--no-deploy`、`DEPLOY_DRY_RUN` 与非法参数。测试不会访问 GitHub，也不会连接服务器。
- 真机演练：`DEPLOY_DRY_RUN=1` 走完下载、校验、上传与远端只读预检，不改动服务器。
- 真实部署仍在开发机的 Git Bash 中触发，CI 只跑离线用例。

## 6. 2026-09-20 真机演练记录

`DEPLOY_DRY_RUN=1` 对运行 `35491634790`（`ubuntu-18.10-amd64-v0.1.4`）的演练暴露了一个本地测试没盖住的问题：

- 本地把安装包上传成 `package.deb`，远端却按包名 `code-server_0.1.4-1_amd64.deb` 执行 `sha256sum -c`，结果 “No such file or directory”，部署在安装前失败。
- 现在本地按原包名上传（`scp ... :<暂存目录>/<包名>`），远端再校验该文件名确实存在；离线用例新增“上传文件名必须等于远端校验名”的断言。

修复后重跑同一次 `--run-id 35491634790`：产物解析、本地校验、上传（31 MB）、远端 `sha256sum -c` 与内置 `node --version`（v24.12.0）预检全部通过，脚本在 dry-run 分支退出，服务器暂存目录被自动清理；`code-server` 仍是 `0.1.4-1`，服务 `active`，`NRestarts=0`。整条链路可用且没有副作用。
