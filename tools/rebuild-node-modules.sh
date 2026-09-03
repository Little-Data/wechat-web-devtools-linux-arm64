#!/bin/bash

set -ex

# ─────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────

notice() {
  echo -e "\033[36m $1 \033[0m "
}

fail() {
  echo -e "\033[41;37m 失败 \033[0m $1"
}

has_https_proxy() {
  [[ -v https_proxy && ${#https_proxy} -gt 0 ]]
}

with_openssl_proxy() {
  if ! has_https_proxy; then
    "$@"
    return
  fi

  (
    set +x
    export GLOBAL_AGENT_HTTP_PROXY="$https_proxy"
    export GLOBAL_AGENT_HTTPS_PROXY="$https_proxy"
    if [[ -n "${no_proxy:-}" ]]; then
      export GLOBAL_AGENT_NO_PROXY="$no_proxy"
    fi
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require=$openssl_proxy_bootstrap"
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY
    set -x
    "$@"
  )
}

# ─────────────────────────────────────────
# 交叉编译判断与环境初始化
# ─────────────────────────────────────────

# 判断是否为 x86_64 → loongarch64 交叉编译
is_loong64_cross() {
  [ "$arch" == "loongarch64" ] && [ "$(uname -m)" == "x86_64" ]
}

# 判断是否为 x86_64 → arm64 交叉编译
is_arm64_cross() {
  [ "$arch" == "arm64" ] && [ "$(uname -m)" == "x86_64" ]
}

# 判断是否处于任意交叉编译模式（在 setup_cross_compile 之后调用才有效）
is_cross_compile() {
  [ -n "${GNU_TRIPLET:-}" ]
}

# 初始化交叉编译工具链环境变量
# 成功后会设置全局变量：GNU_TRIPLET, CROSS_SYSROOT
setup_cross_compile() {
  GNU_TRIPLET=""
  CROSS_SYSROOT=""
  local cross_inc cross_ldflags

  if is_loong64_cross; then
    notice "在x86构建龙架构，准备交叉编译"
    GNU_TRIPLET="loongarch64-unknown-linux-gnu"
    CROSS_SYSROOT="$root_dir/cache/cross-tools/target"
    cross_inc="-I${CROSS_SYSROOT}/usr/include -I${CROSS_SYSROOT}/usr/include/loongarch64-linux-gnu"
    cross_ldflags="-L${CROSS_SYSROOT}/usr/lib64 -L${CROSS_SYSROOT}/usr/lib/loongarch64-linux-gnu"
    export PATH="${CROSS_SYSROOT}/usr/bin:$root_dir/cache/cross-tools/${GNU_TRIPLET}/bin:$root_dir/cache/cross-tools/bin:$PATH"
    "$root_dir/tools/cross/toolchain-prepare-loong64.sh"
  elif is_arm64_cross; then
    notice "在x86构建arm64，准备交叉编译"
    GNU_TRIPLET="aarch64-linux-gnu"
    CROSS_SYSROOT="$root_dir/cache/cross-tools-arm64/target"
    cross_inc="-I${CROSS_SYSROOT}/usr/include -I${CROSS_SYSROOT}/usr/include/aarch64-linux-gnu"
    cross_ldflags="-L${CROSS_SYSROOT}/usr/lib/aarch64-linux-gnu"
    export PATH="${CROSS_SYSROOT}/usr/bin:$PATH"
    # nodegit/utils/buildFlags.js 用 npm_config_arch 决定 targetArch；
    # node-gyp build 不会把它写入子进程环境，导致 nodegit 误判为 x64，
    # 从而把 vendored OpenSSL 按 linux-x86_64 配置（多出 -m64）。这里强制设为 arm64。
    export npm_config_arch="arm64"
    "$root_dir/tools/cross/toolchain-prepare-arm64.sh"
  fi

  if is_cross_compile; then
    export CC="${GNU_TRIPLET}-gcc"
    export CXX="${GNU_TRIPLET}-g++"
    export AR="${GNU_TRIPLET}-ar"
    export LINK="${GNU_TRIPLET}-g++"
    export RANLIB="${GNU_TRIPLET}-ranlib"
    export CFLAGS="$cross_inc"
    export CXXFLAGS="$cross_inc"
    export LDFLAGS="$cross_ldflags"
  fi
}

# ─────────────────────────────────────────
# 构建辅助函数
# ─────────────────────────────────────────

# 交叉编译时，x64 宿主的 node/electron headers common.gypi 里带有 '-m64'，
# 会被写进 nodegit 顶层 Makefile 的 CFLAGS 并沿用（含 acquireOpenSSL 的 OpenSSL make），
# 导致 aarch64-linux-gnu-gcc 报 "unrecognized command-line option '-m64'"。
# 参考 loong64 的 toolchain-prepare-loong64.sh，对交叉编译清理掉 '-m64'。
strip_m64_from_headers() {
  local base="$1"
  [ -n "$base" ] && [ -d "$base" ] || return 0
  find "$base" -type f \( -name 'common.gypi' -o -name 'config.gypi' \) 2>/dev/null | while IFS= read -r f; do
    sed -i "s#'-m64',##g; s#'-m64'##g" "$f" || true
  done
}

# node-gyp configure + build（在子目录内运行）
node_gyp_build() {
  local dir="$1"
  notice "Build $dir (node-gyp)"
  pushd "$dir"
  node-gyp configure "${configure_args[@]}" --target="v$node_version" --openssl_fips=''
  if is_cross_compile; then
    strip_m64_from_headers "$HOME/.cache/node-gyp"
  fi
  node-gyp build
  popd
}

electron_gyp_build() {
  local dir="$1"
  notice "Build $dir (node-gyp)"
  pushd "$dir"
  HOME=~/.electron-gyp node-gyp configure "${configure_args[@]}" --target="$electron_version" --openssl_fips='' --dist-url=https://electronjs.org/headers
  if is_cross_compile; then
    strip_m64_from_headers "$HOME/.electron-gyp/.cache/node-gyp"
  fi
  if [[ "$dir" == "nodegit" ]] && has_https_proxy; then
    notice "Use https_proxy for OpenSSL downloads"
    with_openssl_proxy env HOME="$HOME/.electron-gyp" node-gyp build
  else
    HOME=~/.electron-gyp node-gyp build
  fi
  popd
}
# 在临时叠加 loongarch64 C 兼容标志的子环境中执行任意命令
# 用法：with_loong64_cflags <cmd> [args...]
with_loong64_cflags() {
  (
    if is_loong64_cross; then
      export CFLAGS="$CFLAGS -x c -std=gnu89 -Wno-error=incompatible-pointer-types -Wno-incompatible-pointer-types"
      export CXXFLAGS="$CXXFLAGS -Wno-error=incompatible-pointer-types -Wno-incompatible-pointer-types"
    fi
    "$@"
  )
}

# ─────────────────────────────────────────
# 模块特定构建函数
# ─────────────────────────────────────────

build_nodegit() {
  notice "Build nodegit"
  pushd nodegit
  # https://github.com/nodejs/node-gyp/issues/2673#issuecomment-1196931379
  node-gyp configure "${configure_args[@]}" --target="v$node_version" --openssl_fips=''
  # 交叉编译时需要为 libssh2 的 configure 脚本传入 --host，否则 libssh2 会误判为宿主机架构
  if is_cross_compile; then
    sed -i "s#libssh2ConfigureScript,#\`\${libssh2ConfigureScript} --host=${GNU_TRIPLET}\`,#" \
      utils/configureLibssh2.js
  fi
  node-gyp build
  rm -rf .github include src lifecycleScripts vendor utils build/vendor build/Release/.deps
  popd
}

# ─────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────

root_dir=$(cd "$(dirname "$0")/.." && pwd -P)

$root_dir/tools/asar-helper.sh unpack
package_dir="$root_dir/resources/app"

# TODO: 兼容python2.7的命令
PY_VERSION=$(python -V 2>&1 | awk '{print $2}' | awk -F '.' '{print $1}')
if [ "$PY_VERSION" != "2" ]; then
  hash python2.7 2>/dev/null || hash python2 2>/dev/null || {
    fail "I require python2 but it's not installed.  Aborting."
    exit 1
  }
  mkdir -p "$root_dir/tmp/bin"
  if hash python2.7 2>/dev/null; then
    ln -sf "$(which python2.7)" "$root_dir/tmp/bin/python"
  else
    ln -sf "$(which python2)" "$root_dir/tmp/bin/python"
  fi
fi

arch=$(node "$root_dir/tools/parse-config.js" --get-arch "$@")
setup_cross_compile

echo -e "\033[42;37m ######## 版本信息 $(date '+%Y-%m-%d %H:%M:%S') ########\033[0m"
echo "arch:             $arch"
echo "node version:     $(node --version)"
echo "npm version:      $(npm --version)"
python --version
python3 --version

# ── Windows 专属模块清理 ──────────────────
cd "${package_dir}/node_modules"
rm -fr vscode-windows-ca-certs \
     vscode-windows-registry \
     vscode-windows-registry-node \
     windows-process-tree
find -name "*.pdb" | xargs -I{} rm -rf {}
find -name "*.lib" | xargs -I{} rm -rf {}
find -name "*.dll" | xargs -I{} rm -rf {}
find -name "*.exe" | xargs -I{} rm -rf {}

# ── ripgrep 二进制替换 ────────────────────
# https://github.com/microsoft/ripgrep-prebuilt
ripgrep_version="15.0.0"
case "$arch" in
  arm64)
    ripgrep_triple="aarch64-unknown-linux-musl" ;;
  loongarch64)
    # TODO: 等待上游提供 loongarch64 预编译版本，暂用 x86_64
    ripgrep_triple="x86_64-unknown-linux-musl" ;;
  *)
    ripgrep_triple="x86_64-unknown-linux-musl" ;;
esac
ripgrep_tarball="ripgrep-v${ripgrep_version}-${ripgrep_triple}.tar.gz"
ripgrep_path="$root_dir/cache/$ripgrep_tarball"
mkdir -p "$root_dir/cache"

if [ ! -f "$ripgrep_path" ]; then
  wget "https://github.com/microsoft/ripgrep-prebuilt/releases/download/v${ripgrep_version}/${ripgrep_tarball}" \
    -O "${ripgrep_path}.tmp"
  mv "${ripgrep_path}.tmp" "$ripgrep_path"
fi

rm -fr "${package_dir}/node_modules/@vscode/ripgrep/bin/"*
mkdir -p "${package_dir}/node_modules/@vscode/ripgrep/tmp"
tar xvf "$ripgrep_path" -C "${package_dir}/node_modules/@vscode/ripgrep/bin"
rm -rf "${package_dir}/node_modules/@vscode/ripgrep/tmp"

# ── 安装待重编译的模块源码 ───────────────
rm -fr "${package_dir}/node_modules_tmp"
mkdir -p "${package_dir}/node_modules_tmp/node_modules"

notice "install modules"
export JOBS=$(nproc)
module_packages=(
  extract-file-icon
  native-keymap
  node-pty@1.0.0
  native-watchdog
  @vscode/spdlog@0.13.11
  nodegit@0.28.0-alpha.36
  @vscode/sqlite3
)
if has_https_proxy; then
  module_packages+=(global-agent@3.0.0)
fi
(
  cd "${package_dir}/node_modules_tmp"
  npm install \
    "${module_packages[@]}" \
    --ignore-scripts \
    --registry=https://registry.npmmirror.com \
    --nodegit_binary_host_mirror=https://npmmirror.com/mirrors/nodegit/v0.28.0-alpha.36/
)

if has_https_proxy; then
  openssl_proxy_bootstrap="${package_dir}/node_modules_tmp/node_modules/global-agent/bootstrap.js"
  if [[ ! -f "$openssl_proxy_bootstrap" ]]; then
    fail "OpenSSL代理模块安装失败"
    exit 1
  fi
fi

# ── 逐模块重编译 ──────────────────────────
# 注：每个模块单独 rebuild，交叉编译时可能需要单独调整配置。

cd "${package_dir}/node_modules_tmp/node_modules"

node_version=$(node "$root_dir/tools/parse-config.js" --get-node-version "$@")
electron_version=$(node "$root_dir/tools/parse-config.js" --get-electron-version "$@")
configure_args=(
  --target_platform=linux
  --target_arch="$arch"
  --verbose
  --registry=https://registry.npmmirror.com
)

electron_gyp_build "nodegit"
node_gyp_build "extract-file-icon"
node_gyp_build "native-keymap"
electron_gyp_build "node-pty"
node_gyp_build "native-watchdog"
(cd "@vscode" && electron_gyp_build "spdlog")
(cd "@vscode" && electron_gyp_build "sqlite3")

# ── 清理编译产物冗余文件 ─────────────────
notice "remove unused files"
find . -name ".deps" | xargs -I{} rm -rf {}
find . -name "obj.target" | xargs -I{} rm -rf {}
find . -name "*.a" | xargs -I{} rm -f {}
find . -name "*.lib" -delete
find . -name "*..mk" -delete

# ── 将 .node 文件回写到 Electron 应用目录 ───────
notice "copy node files"
find . -name "*.node" | xargs -I{} cp -rf {} "${package_dir}/node_modules/{}"

rm -rf "${package_dir}/node_modules_tmp"

$root_dir/tools/asar-helper.sh pack
