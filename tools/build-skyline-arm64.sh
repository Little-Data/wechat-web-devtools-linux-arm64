#!/bin/bash
# 在 arm64 上从源码构建 Skyline 所需的两个 NAPI 插件并注入 resources/app（Electron 布局）。
# 上游 msojocs/skyline-* 只发布 linux-x86_64 二进制，arm64 需源码编译。
# 特性是可选的：任一步失败即打印 ::warning 并整体跳过（不影响主构建）。
set -e

root_dir=$(cd "$(dirname "$0")/../.." && pwd -P)
package_dir="$root_dir/resources/app"
cache_dir="$root_dir/cache/skyline"

warn() { echo -e "\033[43;37m 警告 \033[0m [skyline] $1"; }
notice() { echo -e "\033[36m [skyline] $1 \033[0m "; }
fail() { warn "$1，跳过 Skyline 支持（不影响主构建）"; exit 0; }

# 仅在 arm64 目标上处理
if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  notice "非 arm64 宿主，跳过 Skyline 构建"
  exit 0
fi

# ── 前置：解包 resources/app（构建结束被打成 app.asar，需先 unpack）──
notice "unpack resources/app"
"$root_dir/tools/asar-helper.sh" unpack || fail "asar unpack"

# ── vcpkg + spdlog（CMake 依赖 find_package(spdlog REQUIRED)）──
export VCPKG_ROOT="$cache_dir/vcpkg"
if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
  notice "bootstrap vcpkg"
  git clone --depth 1 https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT" \
    || fail "clone vcpkg"
  "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics || fail "bootstrap vcpkg"
fi
notice "vcpkg install spdlog (arm64-linux)"
"$VCPKG_ROOT/vcpkg" install spdlog || fail "vcpkg install spdlog"

# ── 构建一个 NAPI 插件 ──────────────────────────────
# $1: repo(owner/repo)  $2: ref  $3: 仓库内构建子目录  $4: 输出目录  $5: 输出文件名
build_addon() {
  local repo="$1" ref="$2" sub="$3" out_dir="$4" out_name="$5"
  local d="$cache_dir/build/$(basename "$repo")"
  if [ ! -d "$d/.git" ]; then
    notice "clone $repo@$ref"
    git clone --depth 1 -b "$ref" "https://github.com/$repo.git" "$d" || fail "clone $repo"
  fi
  local build_base="$d"
  [ -n "$sub" ] && build_base="$d/$sub"
  (
    cd "$build_base"
    corepack enable 2>/dev/null || npm install -g pnpm@9 || true
    pnpm install --no-frozen-lockfile || fail "$repo pnpm install"
    # NAPI-7 插件，arm64 原生编译（cmake-js 通过 VCPKG_ROOT 找到 spdlog）
    pnpm exec cmake-js compile --arch arm64 --out build/Release --config Release \
      || fail "$repo cmake-js compile"
  )
  mkdir -p "$out_dir"
  local n
  n=$(find "$build_base/build/Release" -name '*.node' 2>/dev/null | head -1)
  [ -n "$n" ] || fail "$repo 未产出 .node"
  cp "$n" "$out_dir/$out_name"
  chmod +x "$out_dir/$out_name"
  notice "built $out_name (arch: $(file -b "$out_dir/$out_name"))"
}

# ── 构建并注入 sharedMemory ─────────────────────────
build_addon "msojocs/skyline-shared-memory" "master" "" \
  "$package_dir/node_modules/sharedMemory" "sharedMemory.node"

# ── 构建并注入 skyline client/node（monorepo：packages/native）──
build_addon "msojocs/skyline-client-server" "master" "packages/native" \
  "$package_dir/node_modules/skyline-addon/build" "skyline.node"

# ── JS 补丁（对齐 replace-skyline.sh，但使用 Electron 布局）──
notice "patch skyline extensions"
inject() {  # $1 target  $2 patch
  local t="$package_dir/$1" p="$root_dir/$2"
  [ -f "$t" ] && [ -f "$p" ] || { warn "补丁文件缺失 $1"; return; }
  local tmpf; tmpf=$(mktemp)
  cat "$p" "$t" > "$tmpf"
  cat "$tmpf" > "$t"
  rm -f "$tmpf"
}
inject "js/extensions/inject/documentstart/index.js" "res/scripts/document_start.js"
inject "js/extensions/skyline/index.js" "res/scripts/skyline.js"

# ── 重新打包 ────────────────────────────────────────
notice "pack resources/app"
"$root_dir/tools/asar-helper.sh" pack || fail "asar pack"

notice "Skyline arm64 插件构建完成（如 skyline 仍需运行 skyline-server 镜像，见 tools/run-skyline-server.sh）"
exit 0
