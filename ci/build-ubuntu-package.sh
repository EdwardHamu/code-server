#!/usr/bin/env bash
# Build amd64 .deb + tarball targeting Ubuntu 18.10 (cosmic, glibc 2.28).
# GitHub-hosted runners are not 18.10; this script vendors a Node 24 linux-x64
# binary whose published minimum is glibc 2.28 / kernel 4.18, matching 18.10.
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

usage() {
  cat <<'HELP'
用法：
  bash ci/build-ubuntu-package.sh --repo-root DIR --tag v0.1.0-lite.1 --output-dir DIR
可选：
  --node-version 24.12.0
  --node-base-url https://nodejs.org/dist
  --node-archive PATH.tarball
  --node-sha256 HEX
HELP
}

deb_version_from_tag() {
  local tag=$1
  tag=${tag#v}
  if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s-1\n' "$tag"
    return
  fi
  printf '%s-1\n' "${tag//-/+}"
}

copy_runtime() {
  local src=$1 dest=$2
  mkdir -p "$dest/lite/public"
  cp -- "$src/lite/server.mjs" "$src/lite/files.mjs" "$src/lite/git.mjs" "$dest/lite/"
  cp -- "$src/lite/public/index.html" "$src/lite/public/app.js" "$src/lite/public/style.css" "$dest/lite/public/"
  cp -- "$src/README.md" "$src/LICENSE" "$dest/"
  if [[ -f $src/docs/mcp-lite-editor.md ]]; then
    mkdir -p "$dest/docs"
    cp -- "$src/docs/mcp-lite-editor.md" "$dest/docs/"
  fi
}

main() {
  local repo_root='' tag='' output_dir='' node_archive='' node_sha256=''
  local node_version=${NODE_VERSION:-24.12.0}
  local node_base_url=${NODE_BASE_URL:-https://nodejs.org/dist}
  while (( $# )); do
    case "$1" in
      --help|-h) usage; return 0 ;;
      --repo-root|--tag|--output-dir|--node-version|--node-base-url|--node-archive|--node-sha256)
        [[ $# -ge 2 && $2 != --* ]] || { log "缺少参数：$1"; return 1; }
        case "$1" in
          --repo-root) repo_root=$2 ;;
          --tag) tag=$2 ;;
          --output-dir) output_dir=$2 ;;
          --node-version) node_version=$2 ;;
          --node-base-url) node_base_url=$2 ;;
          --node-archive) node_archive=$2 ;;
          --node-sha256) node_sha256=$2 ;;
        esac
        shift 2 ;;
      *) log "未知参数：$1"; usage; return 1 ;;
    esac
  done
  [[ -n $repo_root && -d $repo_root/lite && -f $repo_root/lite/server.mjs ]] || { log '需要包含 lite/server.mjs 的 --repo-root'; return 1; }
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || { log '版本标签格式无效'; return 1; }
  [[ $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log 'Node 版本无效'; return 1; }
  [[ -n $output_dir ]] || { log '需要 --output-dir'; return 1; }
  case "$node_base_url" in
    https://nodejs.org/dist|http://127.0.0.1:*) ;;
    *) log '拒绝非 nodejs.org / 本地测试的 Node 下载源'; return 1 ;;
  esac

  repo_root=$(cd "$repo_root" && pwd)
  mkdir -p "$output_dir"
  output_dir=$(cd "$output_dir" && pwd)
  _ubuntu_pkg_work=$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-pkg.XXXXXX")
  work=$_ubuntu_pkg_work
  trap 'rm -rf -- "$_ubuntu_pkg_work"' EXIT

  local tarball_name="node-v${node_version}-linux-x64.tar.xz"
  local tarball=$work/$tarball_name
  if [[ -n $node_archive ]]; then
    cp -- "$node_archive" "$tarball"
  else
    log "下载 Node $node_version linux-x64"
    retry curl -fsSL --connect-timeout 20 --max-time 180 \
      -o "$work/SHASUMS256.txt" "$node_base_url/v${node_version}/SHASUMS256.txt"
    retry curl -fsSL --connect-timeout 20 --max-time 180 \
      -o "$tarball" "$node_base_url/v${node_version}/$tarball_name"
    node_sha256=$(awk -v name="$tarball_name" '$2 == name { print $1 }' "$work/SHASUMS256.txt")
  fi
  [[ $node_sha256 =~ ^[0-9a-fA-F]{64}$ ]] || { log '缺少 Node 压缩包 SHA-256'; return 1; }
  echo "$node_sha256  $tarball" | sha256sum -c -
  mkdir -p "$work/node-src"
  tar -xJf "$tarball" -C "$work/node-src"
  local node_prefix=$work/node-src/node-v${node_version}-linux-x64
  [[ -x $node_prefix/bin/node ]] || { log 'Node 压缩包缺少 bin/node'; return 1; }

  local payload=$work/payload
  mkdir -p "$payload/node/bin"
  cp -- "$node_prefix/bin/node" "$payload/node/bin/node"
  chmod 0755 "$payload/node/bin/node"
  if [[ -f $node_prefix/LICENSE ]]; then
    cp -- "$node_prefix/LICENSE" "$payload/node/LICENSE"
  fi
  copy_runtime "$repo_root" "$payload"
  cat > "$payload/code-server" <<'WRAP'
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
export PATH="$root/node/bin:${PATH:-}"
exec "$root/node/bin/node" "$root/lite/server.mjs" "$@"
WRAP
  chmod 0755 "$payload/code-server"

  local deb_version
  deb_version=$(deb_version_from_tag "$tag")
  local pkgname=code-server_${deb_version}_amd64
  local debian=$work/deb
  mkdir -p "$debian/DEBIAN" "$debian/usr/lib/code-server" "$debian/usr/bin" \
    "$debian/usr/share/doc/code-server"
  cp -a -- "$payload/." "$debian/usr/lib/code-server/"
  cat > "$debian/usr/bin/code-server" <<'WRAP'
#!/bin/sh
set -eu
exec /usr/lib/code-server/code-server "$@"
WRAP
  chmod 0755 "$debian/usr/bin/code-server"
  cp -- "$payload/README.md" "$payload/LICENSE" "$debian/usr/share/doc/code-server/"
  cat > "$debian/DEBIAN/control" <<CTRL
Package: code-server
Version: ${deb_version}
Architecture: amd64
Maintainer: code-server lite packager <noreply@localhost>
Depends: libc6 (>= 2.28), git
Section: devel
Priority: optional
Homepage: https://github.com/coder/code-server
Description: Minimal file editor and Git manager for Ubuntu 18.10
 Bundled Node.js 24 linux-x64 (glibc >= 2.28, kernel >= 4.18) plus the
 lite editor. Target OS is Ubuntu 18.10 cosmic on amd64. Ubuntu 18.10 is
 end-of-life; install only on a host that still provides glibc 2.28.
 This package does not include VS Code, extensions, or a terminal.
CTRL
  printf 'Target: Ubuntu 18.10 (cosmic) amd64\nTag: %s\nNode: %s\n' "$tag" "$node_version" \
    > "$debian/usr/share/doc/code-server/TARGET.txt"

  command -v dpkg-deb >/dev/null || { log '需要 dpkg-deb（在 Ubuntu 打包机或 CI 上运行）'; return 1; }
  local deb_path=$output_dir/${pkgname}.deb
  dpkg-deb --build --root-owner-group "$debian" "$deb_path"
  local tar_path=$output_dir/code-server-${tag#v}-ubuntu18.10-amd64.tar.gz
  tar -C "$payload" --owner=0 --group=0 --numeric-owner -czf "$tar_path" .
  (
    cd "$output_dir"
    sha256sum -- "$(basename "$deb_path")" "$(basename "$tar_path")" > SHA256SUMS
  )
  log "已生成 $(basename "$deb_path") 与 $(basename "$tar_path")（Ubuntu 18.10 amd64）"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
