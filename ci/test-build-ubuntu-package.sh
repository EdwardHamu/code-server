#!/usr/bin/env bash
# Offline package-layout tests. Requires dpkg-deb, tar, xz, sha256sum.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v dpkg-deb >/dev/null || { echo 'SKIP: dpkg-deb not installed'; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/src/lite/public" "$tmp/src/docs" "$tmp/out" "$tmp/node-v24.12.0-linux-x64/bin"
printf '#!/bin/sh\necho fake-node\n' > "$tmp/node-v24.12.0-linux-x64/bin/node"
chmod +x "$tmp/node-v24.12.0-linux-x64/bin/node"
echo 'NODE LICENSE' > "$tmp/node-v24.12.0-linux-x64/LICENSE"
tar -C "$tmp" -cJf "$tmp/node.tar.xz" node-v24.12.0-linux-x64
sha=$(sha256sum "$tmp/node.tar.xz" | awk '{print $1}')
printf 'export const x=1\n' > "$tmp/src/lite/server.mjs"
printf 'export const y=1\n' > "$tmp/src/lite/files.mjs"
printf 'export const z=1\n' > "$tmp/src/lite/git.mjs"
printf 'export const w=1\n' > "$tmp/src/lite/state.mjs"
echo '<html></html>' > "$tmp/src/lite/public/index.html"
echo '/* css */' > "$tmp/src/lite/public/style.css"
echo 'console.log(1)' > "$tmp/src/lite/public/app.js"
echo 'README' > "$tmp/src/README.md"
echo 'MIT' > "$tmp/src/LICENSE"
echo 'docs' > "$tmp/src/docs/mcp-lite-editor.md"
mkdir -p "$tmp/src/src" "$tmp/src/patches"
echo 'should-not-pack' > "$tmp/src/src/secret.ts"
echo 'should-not-pack' > "$tmp/src/patches/x.diff"

# Download retry: first two curl attempts fail, third succeeds.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
n=0; [[ ! -f $MOCK_STATE/curl-n ]] || n=$(cat "$MOCK_STATE/curl-n")
n=$((n+1)); echo "$n" > "$MOCK_STATE/curl-n"
printf '%s\n' "$*" >> "$MOCK_STATE/curl-calls"
if (( n < 3 )); then echo 'network down' >&2; exit 22; fi
out=''
while (( $# )); do
  if [[ $1 == -o ]]; then out=$2; break; fi
  shift
done
[[ -n $out ]]
if [[ $out == *SHASUMS256.txt ]]; then
  printf '%s  node-v24.12.0-linux-x64.tar.xz\n' "$(sha256sum "$FAKE_NODE_TAR" | awk '{print $1}')" > "$out"
else
  cp -- "$FAKE_NODE_TAR" "$out"
fi
MOCK
chmod +x "$tmp/bin/curl"

RETRY_ATTEMPTS=4 RETRY_DELAY_SECONDS=1 PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp" FAKE_NODE_TAR="$tmp/node.tar.xz" \
  bash "$root/ci/build-ubuntu-package.sh" \
  --repo-root "$tmp/src" --tag v0.1.0-lite.1 --output-dir "$tmp/out" \
  --node-version 24.12.0 --node-base-url 'http://127.0.0.1:9'
[[ $(cat "$tmp/curl-n") -eq 4 ]]
[[ -f $tmp/out/code-server_0.1.0+lite.1-1_amd64.deb ]]
[[ -f $tmp/out/code-server-0.1.0-lite.1-ubuntu18.10-amd64.tar.gz ]]
[[ -f $tmp/out/SHA256SUMS ]]
(cd "$tmp/out" && sha256sum -c SHA256SUMS)
dpkg-deb -I "$tmp/out/code-server_0.1.0+lite.1-1_amd64.deb" > "$tmp/info.txt"
grep -q 'Ubuntu 18.10' "$tmp/info.txt"
grep -q 'libc6 (>= 2.28)' "$tmp/info.txt"
grep -q 'Architecture: amd64' "$tmp/info.txt"
dpkg-deb -c "$tmp/out/code-server_0.1.0+lite.1-1_amd64.deb" > "$tmp/contents.txt"
grep -q './usr/bin/code-server' "$tmp/contents.txt"
grep -q './usr/lib/code-server/lite/server.mjs' "$tmp/contents.txt"
grep -q './usr/lib/code-server/lite/state.mjs' "$tmp/contents.txt"
# Every module imported by the runtime must ship in the package.
for module in $(grep -oE "from '\./[a-z]+\.mjs'" "$root/lite/server.mjs" | grep -oE '[a-z]+\.mjs'); do
  grep -q "./usr/lib/code-server/lite/$module" "$tmp/contents.txt" || { echo "FAIL: package missing lite/$module"; exit 1; }
done
grep -q './usr/lib/code-server/node/bin/node' "$tmp/contents.txt"
! grep -q 'secret.ts' "$tmp/contents.txt"
! grep -q 'patches' "$tmp/contents.txt"

# Local archive path still requires a matching SHA-256.
if bash "$root/ci/build-ubuntu-package.sh" --repo-root "$tmp/src" --tag v0.1.0-lite.1 \
  --output-dir "$tmp/bad" --node-archive "$tmp/node.tar.xz" --node-sha256 '00'; then
  echo 'FAIL: unsigned archive accepted'; exit 1
fi
mkdir -p "$tmp/ok"
bash "$root/ci/build-ubuntu-package.sh" --repo-root "$tmp/src" --tag v0.1.0-lite.1 \
  --output-dir "$tmp/ok" --node-archive "$tmp/node.tar.xz" --node-sha256 "$sha"
[[ -f $tmp/ok/code-server_0.1.0+lite.1-1_amd64.deb ]]
echo 'Ubuntu 18.10 package builder tests passed (offline fake Node tarball).'
