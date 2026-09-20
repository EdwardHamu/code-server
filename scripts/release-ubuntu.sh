#!/usr/bin/env bash
# Git Bash/Linux/macOS Bash. All gh/git network calls use bounded, buffered retries.
# Pushes existing commits only; never commits, force-pushes, or cancels remote runs.
# After a successful package run it can deploy that exact run's artifact over an existing
# SSH alias. Credentials stay in the user's SSH configuration; only the verified artifact
# and a plain Bash script are sent, and the server keeps a backup before touching dpkg.
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

urlencode() {
  local LC_ALL=C text=$1 i char
  for ((i=0; i<${#text}; i++)); do
    char=${text:i:1}
    case "$char" in
      [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
      *) printf '%%%02X' "'$char" ;;
    esac
  done
}

# Same rule as ci/build-ubuntu-package.sh: v0.1.4 -> 0.1.4-1, v0.1.0-lite.1 -> 0.1.0+lite.1-1.
debian_version_from_tag() {
  local value=${1#v}
  printf '%s-1\n' "${value//-/+}"
}

one_request() {
  timeout --foreground "${REQUEST_TIMEOUT_SECONDS}s" "$@"
}

retry() {
  local attempt rc=1 delay=$RETRY_DELAY_SECONDS output
  output=$(mktemp "$scratch/response.XXXXXX") || return 1
  for ((attempt=1; attempt<=RETRY_ATTEMPTS; attempt++)); do
    if one_request "$@" >"$output"; then
      cat "$output"
      rm -f "$output"
      return 0
    else
      rc=$?
    fi
    log "请求失败（$attempt/$RETRY_ATTEMPTS，退出码 $rc）：${1:-command} ${2:-}"
    if (( attempt < RETRY_ATTEMPTS )); then
      sleep "$delay"
      delay=$((delay * 2))
      (( delay <= 30 )) || delay=30
    fi
  done
  rm -f "$output"
  return "$rc"
}

notify() {
  local title=$1 body=$2
  if command -v powershell.exe >/dev/null 2>&1; then
    if RELEASE_UBUNTU_NOTIFY_TITLE="$title" RELEASE_UBUNTU_NOTIFY_BODY="$body" \
      timeout --foreground 25s powershell.exe -NoProfile -NonInteractive -Command \
      '$ErrorActionPreference="Stop"; $w=New-Object -ComObject WScript.Shell; [void]$w.Popup($env:RELEASE_UBUNTU_NOTIFY_BODY,15,$env:RELEASE_UBUNTU_NOTIFY_TITLE,4160)' >/dev/null 2>&1; then
      return 0
    fi
  elif command -v osascript >/dev/null 2>&1; then
    if osascript - "$title" "$body" <<'APPLESCRIPT'
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
    then return 0; fi
  elif command -v notify-send >/dev/null 2>&1; then
    if notify-send -- "$title" "$body"; then return 0; fi
  fi
  printf '\a' >&2
  log "无法显示桌面通知（可能没有桌面会话），请查看终端：$title — $body"
  return 0
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ ${notice_done:-0} != 1 ]]; then
    notify 'Ubuntu 打包监控已停止' "${failure_message:-脚本发生错误}（退出码 $rc）。${run_url:-云端任务可能仍在运行；本脚本未取消它。}"
  fi
  [[ -z ${scratch:-} ]] || rm -rf -- "$scratch"
  exit "$rc"
}

github_repo_from_url() {
  local url=${1%/} name
  case "$url" in
    https://github.com/*) name=${url#https://github.com/} ;;
    git@github.com:*) name=${url#git@github.com:} ;;
    ssh://git@github.com/*) name=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  name=${name%.git}
  [[ $name =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s' "$name"
}

push_current_branch() {
  local branch push_url push_repo sha
  branch=$(git symbolic-ref --quiet --short HEAD) || {
    failure_message='分离 HEAD 状态不能自动推送，请切回分支或使用 --allow-remote'
    return 1
  }
  ref=${ref#refs/heads/}
  [[ $ref == "$branch" ]] || {
    failure_message="自动推送只允许当前分支 $branch，不能将它推送到 $ref；仅构建远端其他 ref 请用 --allow-remote"
    return 1
  }
  push_url=$(git remote get-url --push --all origin) || {
    failure_message='无法读取 origin 的推送地址'
    return 1
  }
  [[ -n $push_url && $push_url != *$'\n'* ]] || {
    failure_message='origin 必须只有一个推送地址，拒绝多地址推送'
    return 1
  }
  push_repo=$(github_repo_from_url "$push_url") || {
    failure_message='origin 推送地址必须是明确的 github.com 仓库地址'
    return 1
  }
  [[ $(printf '%s' "$push_repo" | tr '[:upper:]' '[:lower:]') == $(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]') ]] || {
    failure_message="origin 推送仓库 $push_repo 与打包仓库 $repo 不一致，拒绝推送"
    return 1
  }
  sha=$(git rev-parse HEAD) || return 1
  log "自动推送已有提交：$push_repo / $branch @ $sha（不提交、不强推、不推送标签）"
  if ! retry git -c push.followTags=false -c push.recurseSubmodules=no \
    push --porcelain -- "$push_url" "$sha:refs/heads/$branch"; then
    failure_message='自动推送失败：请检查认证/网络、分支保护或先处理远端分叉；未触发构建'
    return 1
  fi
}

find_run() {
  retry gh run list --repo "$repo" --workflow release-ubuntu.yml --event workflow_dispatch \
    --limit 100 --json databaseId,displayTitle \
    --jq ". | map(select(.displayTitle == \"release-ubuntu/$request_id\")) | sort_by(.databaseId) | .[0].databaseId // empty"
}

discover() {
  local deadline=$((SECONDS + DISCOVERY_TIMEOUT_SECONDS)) found
  while (( SECONDS < deadline )); do
    if found=$(find_run); then
      if [[ $found =~ ^[0-9]+$ ]]; then run_id=$found; return 0; fi
    else
      log '查询构建列表失败，继续等待网络恢复。'
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  failure_message="未在限定时间找到请求 $request_id；请用 --request-id $request_id 继续查找，不要盲目重新触发"
  return 124
}

dispatch() {
  local attempt found probe accepted=0
  for ((attempt=1; attempt<=RETRY_ATTEMPTS; attempt++)); do
    if ! found=$(find_run); then
      failure_message="无法确认请求 $request_id 是否已触发，已停止重复写入；可用 --request-id 恢复"
      return 1
    fi
    if [[ $found =~ ^[0-9]+$ ]]; then run_id=$found; return 0; fi
    log "触发 release-ubuntu.yml（请求 $request_id，第 $attempt 次）"
    if one_request gh workflow run release-ubuntu.yml --repo "$repo" --ref "$ref" \
      -f "release_tag=$tag" -f "source_sha=$source_sha" -f "request_id=$request_id"; then
      accepted=1
      break
    fi
    for ((probe=0; probe<12; probe++)); do
      sleep "$RETRY_DELAY_SECONDS"
      if ! found=$(find_run); then
        failure_message="触发响应不明且查询失败；保留请求 ID $request_id，请用 --request-id 恢复"
        return 1
      fi
      if [[ $found =~ ^[0-9]+$ ]]; then run_id=$found; return 0; fi
    done
  done
  if (( ! accepted )); then
    failure_message="触发请求重试耗尽；请先用 --request-id $request_id 核实云端状态"
    return 1
  fi
  discover
}

monitor() {
  local deadline=$((SECONDS + MONITOR_TIMEOUT_SECONDS)) response status conclusion path event previous=''
  run_url="https://github.com/$repo/actions/runs/$run_id"
  log "运行地址：$run_url"
  log "恢复监控：bash scripts/release-ubuntu.sh --repo $repo --run-id $run_id${tag:+ --tag $tag}"
  while (( SECONDS < deadline )); do
    if response=$(retry gh api "repos/$repo/actions/runs/$run_id" \
      --jq '[.status, (.conclusion // "pending"), .html_url, .path, .event] | @tsv'); then
      IFS=$'\t' read -r status conclusion run_url path event <<<"$response"
      if [[ ${path%%@*} != '.github/workflows/release-ubuntu.yml' || $event != workflow_dispatch ]]; then
        failure_message='运行 ID 不属于 release-ubuntu.yml 的手动触发任务，拒绝监控错误任务'
        return 1
      fi
      if [[ "$status/$conclusion" != "$previous" ]]; then
        log "状态：$status / $conclusion"
        previous="$status/$conclusion"
      else
        log "仍在监控：$status"
      fi
      if [[ $status == completed ]]; then
        notice_done=1
        if [[ $conclusion == success ]]; then
          log 'Ubuntu 18.10 安装包打包和 Release 上传完成。'
          [[ -z $tag ]] || log "Release：https://github.com/$repo/releases/tag/$tag"
          notify 'Ubuntu 打包成功' "Ubuntu 18.10 安装包已上传。$run_url${tag:+  Release: https://github.com/$repo/releases/tag/$tag}"
          return 0
        fi
        log "构建未成功：$conclusion。日志：$run_url"
        notify 'Ubuntu 打包未成功' "结果：$conclusion。$run_url"
        [[ $conclusion != cancelled ]] || return 2
        return 1
      fi
    else
      log '本轮查询重试耗尽，保留运行 ID 并继续监控，不重新触发构建。'
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  failure_message="本地监控超时；可用 --run-id $run_id 恢复，云端任务未被取消"
  return 124
}

# --- Automatic deployment after a successful package run ---------------------
# Only the verified artifact of the monitored run is deployed. A missing or expired
# artifact is a hard failure: the script never falls back to "the newest Release".
ssh_options=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

resolve_run_artifact() {
  local found
  if ! found=$(retry gh api --paginate "repos/$repo/actions/runs/$run_id/artifacts" \
    --jq '.artifacts[] | select(.expired == false and (.name | startswith("ubuntu-18.10-amd64-"))) | .name'); then
    failure_message="查询运行 $run_id 的产物失败；请检查网络或 gh 登录状态"
    return 1
  fi
  found=$(printf '%s' "$found" | tr -d '\r')
  if [[ -z $found ]]; then
    failure_message="运行 $run_id 没有未过期的 Ubuntu 产物（可能已超过保留期）；脚本不会回退到 Release 中的最新版本"
    return 1
  fi
  if [[ $found == *$'\n'* ]]; then
    failure_message="运行 $run_id 有多个 Ubuntu 产物，无法确定应部署哪一个"
    return 1
  fi
  artifact=$found
  artifact_tag=${artifact#ubuntu-18.10-amd64-}
  if [[ ! $artifact_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; then
    failure_message="产物名称 $artifact 中没有可识别的版本标签，拒绝部署"
    return 1
  fi
  if [[ -n $tag && $artifact_tag != "$tag" ]]; then
    failure_message="产物标签 $artifact_tag 与本次构建的 $tag 不一致，拒绝部署不匹配的构建"
    return 1
  fi
  tag=$artifact_tag
  expected_version=$(debian_version_from_tag "$tag")
}

fetch_run_package() {
  local candidate actual normalized_actual normalized_expected
  work=$scratch/deploy
  mkdir -p "$work"
  log "运行 $run_id 的产物：$artifact"
  if ! timeout --foreground "${DEPLOY_TIMEOUT_SECONDS}s" gh run download "$run_id" --repo "$repo" \
    --name "$artifact" --dir "$work" >/dev/null; then
    failure_message="下载产物 $artifact 失败；重跑脚本会安全地重新下载，不会重复部署"
    return 1
  fi
  packages=()
  for candidate in "$work"/code-server_*_amd64.deb; do
    [[ -e $candidate ]] || continue
    packages+=("$candidate")
  done
  if (( ${#packages[@]} != 1 )); then
    failure_message="产物中 amd64 安装包数量为 ${#packages[@]}，期望恰好一个"
    return 1
  fi
  package=${packages[0]##*/}
  if [[ ! $package =~ ^code-server_[0-9A-Za-z.+~_-]+_amd64\.deb$ ]]; then
    failure_message="安装包文件名 $package 不符合预期"
    return 1
  fi
  [[ -s $work/SHA256SUMS ]] || { failure_message='产物缺少 SHA256SUMS'; return 1; }
  expected=$(awk -v name="$package" '$2 == name || $2 == "*" name {print $1}' "$work/SHA256SUMS")
  if [[ ! $expected =~ ^[a-fA-F0-9]{64}$ ]]; then
    failure_message="SHA256SUMS 中没有 $package 的有效校验值"
    return 1
  fi
  actual=$(sha256sum -- "${packages[0]}") || { failure_message='无法计算安装包校验值'; return 1; }
  actual=${actual%% *}
  normalized_actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
  normalized_expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
  if [[ $normalized_actual != "$normalized_expected" ]]; then
    failure_message="安装包校验失败：$package 与 SHA256SUMS 不一致"
    return 1
  fi
}

deploy_run_package() {
  local remote rc=0
  if ! remote=$(one_request ssh "${ssh_options[@]}" "$deploy_host" mktemp -d /tmp/code-server-deploy.XXXXXXXX); then
    failure_message="无法通过 ssh $deploy_host 创建远端暂存目录；请确认 SSH 别名与免密登录可用"
    return 1
  fi
  remote=$(printf '%s' "$remote" | tr -d '\r\n')
  if [[ ! $remote =~ ^/tmp/code-server-deploy\.[A-Za-z0-9]+$ ]]; then
    failure_message="远端返回的暂存目录异常：$remote"
    return 1
  fi
  log "远端暂存目录：$remote"
  if ! timeout --foreground "${DEPLOY_TIMEOUT_SECONDS}s" scp "${ssh_options[@]}" \
    "${packages[0]}" "$deploy_host:$remote/$package"; then
    failure_message="上传安装包到 $deploy_host:$remote 失败；远端未做任何修改"
    return 1
  fi
  # Single attempt on purpose: a lost SSH response may mean the remote step already ran.
  log '开始远端校验、备份、安装并重启服务…'
  timeout --foreground "${DEPLOY_TIMEOUT_SECONDS}s" ssh "${ssh_options[@]}" "$deploy_host" \
    env "DEPLOY_DRY_RUN=$deploy_dry_run" bash -s -- \
    "$remote" "$expected" "$package" "$tag" "$expected_version" \
    "$deploy_local_url" "$deploy_public_url" \
    2>&1 <<'DEPLOY_REMOTE' | tee "$scratch/deploy-remote.log" || rc=$?
# DEPLOY_REMOTE_BEGIN
set -Eeuo pipefail
stage=$1 expected=$2 package_name=$3 tag=$4 expected_version=$5 local_url=$6 public_url=$7
[[ $stage =~ ^/tmp/code-server-deploy\.[A-Za-z0-9]+$ ]] || { echo "Bad staging path: $stage" >&2; exit 1; }
[[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Bad checksum: $expected" >&2; exit 1; }
[[ $package_name =~ ^code-server_[0-9A-Za-z.+~_-]+_amd64\.deb$ ]] || { echo "Bad package name: $package_name" >&2; exit 1; }
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || { echo "Bad tag: $tag" >&2; exit 1; }
[[ $expected_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([+~][0-9A-Za-z.+~]+)?-1$ ]] || { echo "Bad Debian version: $expected_version" >&2; exit 1; }
[[ $local_url =~ ^http://127\.0\.0\.1:[0-9]{1,5}/ ]] || { echo "Bad local URL: $local_url" >&2; exit 1; }
[[ $public_url =~ ^https?:// ]] || { echo "Bad public URL: $public_url" >&2; exit 1; }
[[ $(id -u) == 0 ]] || { echo 'Deployment requires a root SSH user' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/code-server-deploy.lock
  flock -n 9 || { echo 'Another deployment is already running' >&2; exit 1; }
fi
backup=''
cleanup_remote() {
  local rc=$?
  [[ -z $backup ]] || echo "Backup kept: $backup" >&2
  if (( rc )); then echo "Deployment failed (exit $rc); staging kept for inspection: $stage" >&2
  else rm -rf -- "$stage"; fi
}
trap cleanup_remote EXIT
cd "$stage"
[[ -f $package_name ]] || { echo "Uploaded package $package_name is missing in $stage" >&2; exit 1; }
printf '%s  %s\n' "$expected" "$package_name" | sha256sum -c -
[[ $(dpkg-deb -f "$package_name" Package) == code-server ]] || { echo 'Unexpected package name inside deb' >&2; exit 1; }
[[ $(dpkg-deb -f "$package_name" Architecture) == amd64 ]] || { echo 'Unexpected architecture inside deb' >&2; exit 1; }
version=$(dpkg-deb -f "$package_name" Version)
[[ $version == "$expected_version" ]] || { echo "Package version $version does not match expected $expected_version for tag $tag" >&2; exit 1; }
unit=code-server-lite.service
systemctl cat "$unit" >/dev/null || { echo "Systemd unit $unit not found" >&2; exit 1; }
rm -rf preflight
dpkg-deb -x "$package_name" preflight
./preflight/usr/lib/code-server/node/bin/node --version
if [[ ${DEPLOY_DRY_RUN:-0} == 1 ]]; then
  echo "Dry run: $package_name ($version) verified; backup, install and restart skipped"
  exit 0
fi
umask 077
backup=$(mktemp -d /root/code-server-backup.XXXXXXXX)
tar -czf "$backup/program-config.tar.gz" -C / \
  usr/lib/code-server usr/bin/code-server etc/code-server-lite etc/systemd/system/code-server-lite.service
cp -a /var/lib/dpkg/info/code-server.* "$backup/" 2>/dev/null || true
dpkg-query -s code-server > "$backup/package-status.txt" 2>/dev/null || true
echo "Backup directory: $backup"
dpkg --force-confold -i "$package_name"
systemctl restart "$unit"
healthy=0
for ((attempt=0; attempt<15; attempt++)); do
  if systemctl is-active --quiet "$unit" \
    && [[ $(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "$local_url" || true) == 200 ]]; then
    healthy=1
    break
  fi
  sleep 2
done
if (( ! healthy )); then
  journalctl -u "$unit" -n 30 --no-pager >&2 || true
  echo "Service $unit is not healthy after restart" >&2
  exit 1
fi
installed=$(dpkg-query -W -f='${Version}' code-server)
[[ $installed == "$version" ]] || { echo "Installed version $installed does not match $version" >&2; exit 1; }
public_code=$(curl --max-time 20 -sS -o /dev/null -w '%{http_code}' "$public_url" || true)
[[ $public_code == 200 ]] || { echo "Public endpoint $public_url returned ${public_code:-no response} instead of 200" >&2; exit 1; }
echo "Deployed code-server $version"
# DEPLOY_REMOTE_END
DEPLOY_REMOTE
  if (( rc != 0 )); then
    failure_message="远端部署失败（退出码 $rc）；上方输出包含原因与备份目录，脚本不会自动回滚"
    return 1
  fi
}

deploy_release() {
  if ! resolve_run_artifact; then return 1; fi
  if ! fetch_run_package; then return 1; fi
  if ! deploy_run_package; then return 1; fi
  if (( deploy_dry_run )); then
    log "演练通过：$tag（来源运行：$run_url），远端未做任何修改"
  else
    log "已部署 $tag（来源运行：$run_url）"
  fi
}

deploy_after_success() {
  local rc=0
  log "打包成功，开始自动部署：运行 $run_id（SSH 别名 $deploy_host，回环 $deploy_local_url）"
  if deploy_release; then
    if (( deploy_dry_run )); then
      log 'DEPLOY_DRY_RUN=1：未备份、未安装、未重启服务。'
      notify 'Ubuntu 部署演练完成' "DEPLOY_DRY_RUN=1：产物已校验并上传，远端只做只读预检，没有安装。$run_url"
    else
      log "自动部署完成：$tag"
      notify 'Ubuntu 打包并部署成功' "$tag 已安装并重启服务。$run_url"
    fi
    notice_done=1
    return 0
  else
    rc=$?
  fi
  log "自动部署失败：${failure_message}"
  notify 'Ubuntu 打包成功但部署失败' "${failure_message}（运行日志：$run_url）"
  notice_done=1
  return 3
}

usage() {
  cat <<'HELP'
用法：
  bash scripts/release-ubuntu.sh --tag v0.1.0-lite.1 [--ref main] [--repo owner/name] [--no-deploy]
  bash scripts/release-ubuntu.sh --repo owner/name --run-id 123456 [--tag v0.1.0-lite.1] [--no-deploy]
  bash scripts/release-ubuntu.sh --repo owner/name --request-id REQUEST_ID [--no-deploy]
  bash scripts/release-ubuntu.sh --notify-test

默认从 origin 读取仓库名，从当前分支读取 ref；打包前自动推送已有提交。
未提交改动必须先手动提交。推送仅限当前分支，目标仓库必须与打包仓库一致。
触发并监控 .github/workflows/release-ubuntu.yml（Ubuntu 18.10 amd64 安装包）。
首次使用时该 workflow 必须已存在于默认分支。
--allow-remote 跳过本地检查和自动推送，明确只构建远端代码。

监控到 conclusion=success 后自动部署该次运行的产物（默认开启）：
  1. 只使用该 run 的 artifact；缺失或过期直接失败，不会回退到 Release 最新版本；
  2. artifact 名称中的标签必须与本次构建标签一致；
  3. 本地按 SHA256SUMS 校验安装包，再经 scp 上传到服务器（沿用已有 SSH 别名）；
  4. 服务器上先执行新 node 预检、备份 /usr/lib/code-server、/usr/bin/code-server、
     /etc/code-server-lite 与 systemd 单元，再 dpkg --force-confold 安装；
  5. 重启 unit 后验证回环地址与公网地址均返回 200，版本与标签要求一致。
  --no-deploy 只监控不部署；--deploy-host 指定 SSH 别名（默认 vultr）。
  DEPLOY_DRY_RUN=1 会照常下载、校验并上传安装包，在服务器完成只读预检后退出，
  不备份、不安装、不重启，可用于演练整条链路。
  部署失败退出码为 3，服务器上的备份目录会保留，脚本不做自动回滚。
脚本不会自动提交、强推、推送标签、修改版本号或取消云端任务。Ctrl+C 仅停止本地监控。
依赖：Bash、git、已登录的 gh、GNU timeout、ssh、scp、sha256sum；Windows 请在 Git Bash 中运行。
退出码：0 成功（含部署成功）1 打包/配置错误 2 云端任务被取消 3 打包成功但部署失败 124 超时
环境：RETRY_ATTEMPTS=5 RETRY_DELAY_SECONDS=2 REQUEST_TIMEOUT_SECONDS=90
      POLL_INTERVAL_SECONDS=15 DISCOVERY_TIMEOUT_SECONDS=300 MONITOR_TIMEOUT_SECONDS=14400
      DEPLOY_TIMEOUT_SECONDS=300 DEPLOY_SSH_HOST=vultr DEPLOY_DRY_RUN=0
      DEPLOY_LOCAL_URL=http://127.0.0.1:8444/vscode/ DEPLOY_PUBLIC_URL=https://meamoe.top/vscode/
HELP
}

main() {
  set -Eeuo pipefail
  export GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_PAGER=cat
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  repo='' ref='' tag='' run_id='' request_id='' source_sha='' run_url=''
  artifact='' package='' expected='' expected_version='' work=''
  deploy_host=${DEPLOY_SSH_HOST:-vultr}
  deploy_local_url=${DEPLOY_LOCAL_URL:-http://127.0.0.1:8444/vscode/}
  deploy_public_url=${DEPLOY_PUBLIC_URL:-https://meamoe.top/vscode/}
  deploy_dry_run=${DEPLOY_DRY_RUN:-0}
  local allow_remote=0 notify_test=0 deploy_requested=1 option value tool remote sha_local rc=0
  RETRY_ATTEMPTS=${RETRY_ATTEMPTS:-5}
  RETRY_DELAY_SECONDS=${RETRY_DELAY_SECONDS:-2}
  REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-90}
  POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-15}
  DISCOVERY_TIMEOUT_SECONDS=${DISCOVERY_TIMEOUT_SECONDS:-300}
  MONITOR_TIMEOUT_SECONDS=${MONITOR_TIMEOUT_SECONDS:-14400}
  DEPLOY_TIMEOUT_SECONDS=${DEPLOY_TIMEOUT_SECONDS:-300}
  for value in "$RETRY_ATTEMPTS" "$RETRY_DELAY_SECONDS" "$REQUEST_TIMEOUT_SECONDS" "$POLL_INTERVAL_SECONDS" "$DISCOVERY_TIMEOUT_SECONDS" "$MONITOR_TIMEOUT_SECONDS" "$DEPLOY_TIMEOUT_SECONDS"; do
    [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { log '超时/重试参数必须为正整数（最多 6 位）'; return 1; }
  done
  (( RETRY_ATTEMPTS <= 10 )) || { log 'RETRY_ATTEMPTS 最大 10'; return 1; }
  while (( $# )); do
    option=$1; shift
    case "$option" in
      --help|-h) usage; return 0 ;;
      --allow-remote) allow_remote=1 ;;
      --no-deploy) deploy_requested=0 ;;
      --notify-test) notify_test=1 ;;
      --repo|--ref|--tag|--run-id|--request-id|--deploy-host)
        (( $# )) || { log "$option 缺少参数"; return 1; }
        value=$1; shift
        [[ -n $value && $value != --* ]] || { log "$option 参数无效"; return 1; }
        case "$option" in
          --repo) repo=$value ;; --ref) ref=$value ;; --tag) tag=$value ;;
          --run-id) run_id=$value ;; --request-id) request_id=$value ;;
          --deploy-host) deploy_host=$value ;;
        esac ;;
      *) log "未知参数：$option"; usage; return 1 ;;
    esac
  done
  command -v timeout >/dev/null && timeout --version 2>/dev/null | grep -q 'GNU coreutils' || { log '需要 GNU timeout（Windows 使用 Git Bash）'; return 1; }
  if (( notify_test )); then notify 'Ubuntu 打包通知测试' '通知组件工作正常。此操作不会触发构建。'; return 0; fi
  command -v gh >/dev/null || { log '请安装 GitHub CLI 并执行 gh auth login'; return 1; }
  if (( deploy_requested )); then
    for tool in ssh scp sha256sum; do
      command -v "$tool" >/dev/null || { log "自动部署需要 $tool；如只需监控打包请加 --no-deploy"; return 1; }
    done
  fi
  if [[ -z $repo ]]; then
    remote=$(git remote get-url origin) || { log '请使用 --repo owner/name 指定仓库'; return 1; }
    case "$remote" in
      https://github.com/*) repo=${remote#https://github.com/} ;;
      git@github.com:*) repo=${remote#git@github.com:} ;;
      ssh://git@github.com/*) repo=${remote#ssh://git@github.com/} ;;
      *) log 'origin 不是 github.com 地址，请显式指定 --repo'; return 1 ;;
    esac
    repo=${repo%.git}
  fi
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log '仓库格式应为 owner/name'; return 1; }
  [[ -z $tag || $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || { log '版本标签格式无效'; return 1; }
  [[ -z $run_id || $run_id =~ ^[1-9][0-9]*$ ]] || { log '运行 ID 必须是正整数'; return 1; }
  [[ -z $request_id || $request_id =~ ^[A-Za-z0-9-]{1,80}$ ]] || { log '请求 ID 格式无效'; return 1; }
  [[ -z $run_id || -z $request_id ]] || { log '--run-id 与 --request-id 不能同时指定'; return 1; }
  [[ $deploy_host =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || { log '--deploy-host 必须是合法的 SSH 别名'; return 1; }
  [[ $deploy_local_url =~ ^http://127\.0\.0\.1:[0-9]{1,5}/ ]] || { log 'DEPLOY_LOCAL_URL 必须是 http://127.0.0.1:端口/ 形式'; return 1; }
  [[ $deploy_public_url =~ ^https?:// ]] || { log 'DEPLOY_PUBLIC_URL 必须是 http(s) URL'; return 1; }
  [[ $deploy_dry_run =~ ^[01]$ ]] || { log 'DEPLOY_DRY_RUN 只能是 0 或 1'; return 1; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/release-ubuntu.XXXXXX")
  notice_done=0
  failure_message='脚本发生错误；请检查终端输出'
  trap cleanup EXIT
  trap 'failure_message="收到中断，仅停止本地监控；云端任务未取消"; exit 130' INT
  trap 'failure_message="收到终止信号，仅停止本地监控；云端任务未取消"; exit 143' TERM
  if [[ -n $run_id ]]; then
    monitor || rc=$?
  elif [[ -n $request_id ]]; then
    if discover; then monitor || rc=$?; else rc=$?; fi
  else
  [[ -n $tag ]] || { failure_message='必须使用 --tag 指定 Release 标签'; return 1; }
  [[ -n $ref ]] || ref=$(git symbolic-ref --quiet --short HEAD) || { failure_message='分离 HEAD 状态请使用 --ref'; return 1; }
  if (( ! allow_remote )); then
    local worktree_status
    worktree_status=$(git status --porcelain) || { failure_message='无法读取 Git 工作区状态'; return 1; }
    [[ -z $worktree_status ]] || { failure_message='工作区尚未提交，请先手动提交；脚本只自动推送已有提交，或用 --allow-remote 构建远端代码'; return 1; }
    push_current_branch
  fi
  source_sha=$(retry gh api "repos/$repo/commits/$(urlencode "$ref")" --jq '.sha')
  [[ $source_sha =~ ^[0-9a-fA-F]{40}$ ]] || { failure_message='远端提交 SHA 无效'; return 1; }
  if (( ! allow_remote )); then
    sha_local=$(git rev-parse HEAD)
    [[ $sha_local == "$source_sha" ]] || { failure_message='推送后本地 HEAD 与远端 ref 不一致（可能被并发修改），已停止构建；请核实后重试'; return 1; }
  fi
  retry gh api "repos/$repo/actions/workflows/release-ubuntu.yml" --jq '.state' >/dev/null
  request_id="$(date -u '+%Y%m%dT%H%M%S')-$$-$RANDOM-$RANDOM"
  log "仓库：$repo；ref：$ref；固定源码：$source_sha；Release：$tag"
  log "请求 ID：$request_id（如触发结果不明，用 --request-id 此值恢复）"
  if dispatch; then monitor || rc=$?; else rc=$?; fi
  fi
  (( rc == 0 )) || return "$rc"
  if (( ! deploy_requested )); then
    log "已按 --no-deploy 跳过自动部署；如需部署可对本次运行重跑：bash scripts/release-ubuntu.sh --repo $repo --run-id $run_id"
    return 0
  fi
  deploy_after_success
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
