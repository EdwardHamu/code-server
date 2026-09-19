#!/usr/bin/env bash
# Create a GitHub Release for the Ubuntu 18.10 packages in dist/.
# A missing release (HTTP 404) is success-to-create, not a script failure.
set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

retry() {
  local attempt=1 delay=${RETRY_DELAY_SECONDS:-2} rc=1
  while (( attempt <= ${RETRY_ATTEMPTS:-5} )); do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    log "命令失败（$attempt/${RETRY_ATTEMPTS:-5}，退出码 $rc）：$*"
    if (( attempt < ${RETRY_ATTEMPTS:-5} )); then
      sleep "$delay"
      delay=$((delay * 2))
      (( delay <= 30 )) || delay=30
    fi
    attempt=$((attempt + 1))
  done
  return "$rc"
}

http_status_from_headers() {
  tr -d '\r' < "$1" | awk '/^HTTP\// { print $2; exit }'
}

# Prints the HTTP status code. Return 0 if a 3-digit code was parsed,
# including 404 (release missing). Return 1 only when the response is unusable.
lookup_release_status() {
  local out err rc http
  out=$(mktemp)
  err=$(mktemp)
  set +e
  gh api -X GET "repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}" --include >"$out" 2>"$err"
  rc=$?
  set -e
  http=$(http_status_from_headers "$out")
  if [[ $http =~ ^[0-9]{3}$ ]]; then
    printf '%s' "$http"
    rm -f "$out" "$err"
    return 0
  fi
  log "无法解析 Release 查询的 HTTP 状态（gh 退出码 $rc）"
  if [[ -s $err ]]; then cat "$err" >&2; fi
  if [[ -s $out ]]; then head -c 800 "$out" >&2; printf '\n' >&2; fi
  rm -f "$out" "$err"
  return 1
}

write_notes() {
  cat <<EOF
Ubuntu 18.10 (cosmic) amd64 installer for code-server lite.

- Target: Ubuntu 18.10, glibc >= 2.28, amd64
- Bundled Node.js ${NODE_VERSION:-unknown} linux-x64
- Source: \`${SOURCE_SHA}\`
- Request: \`${REQUEST_ID:-none}\`

Ubuntu 18.10 is end-of-life. Install with:

\`\`\`bash
sudo apt-get install ./code-server_*_amd64.deb
\`\`\`

Git is required on the host. Set PASSWORD and run \`code-server --root /path\`.
EOF
}

main() {
  : "${RELEASE_TAG:?RELEASE_TAG is required}"
  : "${SOURCE_SHA:?SOURCE_SHA is required}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
  [[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || { log '版本标签格式无效'; return 1; }
  [[ $SOURCE_SHA =~ ^[0-9a-fA-F]{40}$ ]] || { log 'SOURCE_SHA 无效'; return 1; }
  [[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log 'GITHUB_REPOSITORY 无效'; return 1; }

  local dist=$GITHUB_WORKSPACE/dist
  shopt -s nullglob
  local files=("$dist"/*.deb "$dist"/*.tar.gz)
  local sums=$dist/SHA256SUMS
  shopt -u nullglob
  [[ -f $sums && -s $sums && ${#files[@]} -ge 2 ]] || {
    log "缺少 dist 中的 .deb / .tar.gz / SHA256SUMS"
    ls -la "$dist" >&2 || true
    return 1
  }

  local attempt http='' exists=''
  for ((attempt=1; attempt<=${RETRY_ATTEMPTS:-5}; attempt++)); do
    http=''
    if http=$(lookup_release_status); then
      case "$http" in
        200) exists=1; break ;;
        404) exists=0; break ;;
        *) log "Release 查询 HTTP $http（第 $attempt 次），将重试" ;;
      esac
    else
      log "Release 查询无有效状态（第 $attempt 次），将重试"
    fi
    if (( attempt < ${RETRY_ATTEMPTS:-5} )); then
      sleep $((attempt * 2))
    fi
  done
  [[ -n $exists ]] || { log "无法确认 $RELEASE_TAG 是否已存在，已停止创建"; return 1; }
  if [[ $exists == 1 ]]; then
    log "Release $RELEASE_TAG 已存在，拒绝覆盖"
    return 1
  fi

  local notes
  notes=$(mktemp)
  write_notes > "$notes"
  log "创建 Release $RELEASE_TAG（源码 $SOURCE_SHA）"
  retry gh release create "$RELEASE_TAG" "${files[@]}" "$sums" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$SOURCE_SHA" \
    --title "Ubuntu 18.10 $RELEASE_TAG" \
    --notes-file "$notes"
  log "Release 已上传：https://github.com/${GITHUB_REPOSITORY}/releases/tag/${RELEASE_TAG}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
