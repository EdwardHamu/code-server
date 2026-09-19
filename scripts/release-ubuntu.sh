#!/usr/bin/env bash
# Git Bash/Linux/macOS Bash. All gh/git network calls use bounded, buffered retries.
# Pushes existing commits only; never commits, force-pushes, or cancels remote runs.
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

usage() {
  cat <<'HELP'
用法：
  bash scripts/release-ubuntu.sh --tag v0.1.0-lite.1 [--ref main] [--repo owner/name]
  bash scripts/release-ubuntu.sh --repo owner/name --run-id 123456 [--tag v0.1.0-lite.1]
  bash scripts/release-ubuntu.sh --repo owner/name --request-id REQUEST_ID
  bash scripts/release-ubuntu.sh --notify-test

默认从 origin 读取仓库名，从当前分支读取 ref；打包前自动推送已有提交。
未提交改动必须先手动提交。推送仅限当前分支，目标仓库必须与打包仓库一致。
触发并监控 .github/workflows/release-ubuntu.yml（Ubuntu 18.10 amd64 安装包）。
首次使用时该 workflow 必须已存在于默认分支。
--allow-remote 跳过本地检查和自动推送，明确只构建远端代码。
脚本不会自动提交、强推、推送标签、修改版本号或取消云端任务。Ctrl+C 仅停止本地监控。
依赖：Bash、git、已登录的 gh、GNU timeout；Windows 请在 Git Bash 中运行。
环境：RETRY_ATTEMPTS=5 RETRY_DELAY_SECONDS=2 REQUEST_TIMEOUT_SECONDS=90
      POLL_INTERVAL_SECONDS=15 DISCOVERY_TIMEOUT_SECONDS=300 MONITOR_TIMEOUT_SECONDS=14400
HELP
}

main() {
  set -Eeuo pipefail
  export GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_PAGER=cat
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  repo='' ref='' tag='' run_id='' request_id='' source_sha='' run_url=''
  local allow_remote=0 notify_test=0 option value remote sha_local
  RETRY_ATTEMPTS=${RETRY_ATTEMPTS:-5}
  RETRY_DELAY_SECONDS=${RETRY_DELAY_SECONDS:-2}
  REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-90}
  POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-15}
  DISCOVERY_TIMEOUT_SECONDS=${DISCOVERY_TIMEOUT_SECONDS:-300}
  MONITOR_TIMEOUT_SECONDS=${MONITOR_TIMEOUT_SECONDS:-14400}
  for value in "$RETRY_ATTEMPTS" "$RETRY_DELAY_SECONDS" "$REQUEST_TIMEOUT_SECONDS" "$POLL_INTERVAL_SECONDS" "$DISCOVERY_TIMEOUT_SECONDS" "$MONITOR_TIMEOUT_SECONDS"; do
    [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { log '超时/重试参数必须为正整数（最多 6 位）'; return 1; }
  done
  (( RETRY_ATTEMPTS <= 10 )) || { log 'RETRY_ATTEMPTS 最大 10'; return 1; }
  while (( $# )); do
    option=$1; shift
    case "$option" in
      --help|-h) usage; return 0 ;;
      --allow-remote) allow_remote=1 ;;
      --notify-test) notify_test=1 ;;
      --repo|--ref|--tag|--run-id|--request-id)
        (( $# )) || { log "$option 缺少参数"; return 1; }
        value=$1; shift
        [[ -n $value && $value != --* ]] || { log "$option 参数无效"; return 1; }
        case "$option" in
          --repo) repo=$value ;; --ref) ref=$value ;; --tag) tag=$value ;;
          --run-id) run_id=$value ;; --request-id) request_id=$value ;;
        esac ;;
      *) log "未知参数：$option"; usage; return 1 ;;
    esac
  done
  command -v timeout >/dev/null && timeout --version 2>/dev/null | grep -q 'GNU coreutils' || { log '需要 GNU timeout（Windows 使用 Git Bash）'; return 1; }
  if (( notify_test )); then notify 'Ubuntu 打包通知测试' '通知组件工作正常。此操作不会触发构建。'; return 0; fi
  command -v gh >/dev/null || { log '请安装 GitHub CLI 并执行 gh auth login'; return 1; }
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
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/release-ubuntu.XXXXXX")
  notice_done=0
  failure_message='脚本发生错误；请检查终端输出'
  trap cleanup EXIT
  trap 'failure_message="收到中断，仅停止本地监控；云端任务未取消"; exit 130' INT
  trap 'failure_message="收到终止信号，仅停止本地监控；云端任务未取消"; exit 143' TERM
  if [[ -n $run_id ]]; then monitor; return; fi
  if [[ -n $request_id ]]; then discover; monitor; return; fi
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
  dispatch
  monitor
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
