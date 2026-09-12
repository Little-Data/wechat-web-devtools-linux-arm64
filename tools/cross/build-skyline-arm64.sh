#!/bin/bash
# 在 arm64 上从源码构建 Skyline 所需的两个 NAPI 插件并注入 resources/app（Electron 布局）。
# 上游 msojocs/skyline-* 只发布 linux-x86_64 二进制，arm64 需源码编译。
# 特性是可选的：任一步失败即打印 ::warning 并整体跳过（不影响主构建）。
set -e

root_dir=$(cd "$(dirname "$0")/../.." && pwd -P)
package_dir="$root_dir/resources/app"
cache_dir="$root_dir/cache/skyline"
staging_dir="$cache_dir/out"

warn() { echo -e "\033[43;37m 警告 \033[0m [skyline] $1"; }
notice() { echo -e "\033[36m [skyline] $1 \033[0m "; }
fail() { warn "$1，跳过 Skyline 支持（不影响主构建）"; exit 0; }

# 安全网：若因失败导致 resources/app 处于解包状态，退出前重新打包，
# 避免产物缺少 app.asar（否则 wcc/wcsc 等 unpacked 文件会随之“消失”）。
repack_if_needed() {
  if [ -d "$package_dir" ] && [ ! -f "$root_dir/resources/app.asar" ]; then
    warn "resources/app 处于解包状态，重新打包"
    "$root_dir/tools/asar-helper.sh" pack >/dev/null 2>&1 || true
  fi
}
trap repack_if_needed EXIT

# 仅在 arm64 目标上处理
if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  notice "非 arm64 宿主，跳过 Skyline 构建"
  exit 0
fi

# ── vcpkg + 依赖 ──
# 按宿主架构设定 vcpkg triplet：arm64 宿主必须用 arm64-linux，否则 vcpkg 会去检测/构建 x64-linux 而失败。
host_arch=$(uname -m)
case "$host_arch" in
  aarch64|arm64) SKYLINE_TRIPLET="arm64-linux" ;;
  *)             SKYLINE_TRIPLET="x64-linux" ;;
esac
notice "vcpkg triplet: $SKYLINE_TRIPLET"
export VCPKG_ROOT="$cache_dir/vcpkg"
export VCPKG_DEFAULT_TRIPLET="$SKYLINE_TRIPLET"
export VCPKG_TARGET_TRIPLET="$SKYLINE_TRIPLET"
export VCPKG_HOST_TRIPLET="$SKYLINE_TRIPLET"
if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
  notice "bootstrap vcpkg"
  git clone --depth 1 https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT" \
    || fail "clone vcpkg"
  "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics || fail "bootstrap vcpkg"
fi
# skyline-shared-memory 需要 spdlog；
# skyline-client-server 还需要 nlohmann-json / boost-asio / boost-thread（见其 vcpkg.json）。
notice "vcpkg install deps ($SKYLINE_TRIPLET)"
"$VCPKG_ROOT/vcpkg" install \
  spdlog nlohmann-json boost-asio boost-thread \
  --triplet "$SKYLINE_TRIPLET" \
  || fail "vcpkg install deps"

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

  # 上游 CMakeLists 针对 x64/Windows 写死了若干设置，这里统一补丁成 arm64-linux：
  # - TARGET_ARCH 固定为 x64，会导致 cmake-js 取 x64 头文件；
  # - 默认 triplet 写死 x64-linux（且 FORCE），arm64 上会导致 vcpkg 检测/编译 x64 失败；
  # - 部分版本工具链路径写成 tools/buildsystems（应为 scripts/buildsystems）。
  local cmk="$build_base/CMakeLists.txt"
  if [ -f "$cmk" ]; then
    sed -i \
      -e "s#set(TARGET_ARCH x64)#set(TARGET_ARCH arm64)#" \
      -e "s#set(_skyline_default_triplet .*-linux)#set(_skyline_default_triplet ${SKYLINE_TRIPLET})#" \
      -e "s#set(VCPKG_HOST_TRIPLET .*-linux)#set(VCPKG_HOST_TRIPLET ${SKYLINE_TRIPLET})#" \
      -e "s#/tools/buildsystems/vcpkg.cmake#/scripts/buildsystems/vcpkg.cmake#g" \
      "$cmk" 2>/dev/null || true
    notice "patched $cmk"
  fi

  # 强制经典模式：移除 vcpkg manifest，改用上面 `vcpkg install` 的依赖，
  # 避免 manifest 模式基线/网络导致的失败。
  rm -f "$build_base/vcpkg.json" "$build_base/vcpkg-configuration.json"

  (
    cd "$build_base"
    corepack enable 2>/dev/null || npm install -g pnpm@9 || true
    # --ignore-scripts：跳过 shared-memory 的 prepare（会下载仅 Windows 需要的 nwjs node.lib）
    pnpm install --no-frozen-lockfile --ignore-scripts || fail "$repo pnpm install"
    # NAPI-7 插件，arm64 原生编译（cmake-js 通过 VCPKG_ROOT 找到已安装依赖）
    pnpm exec cmake-js compile --arch arm64 --out build/Release --config Release \
      || fail "$repo cmake-js compile"
  )
  mkdir -p "$out_dir"
  local n
  # 产物可能落在 build/ 或 build/Release（具体取决于模块的 CMAKE_LIBRARY_OUTPUT_DIRECTORY），递归查找
  n=$(find "$build_base/build" -name '*.node' 2>/dev/null | head -1)
  [ -n "$n" ] || fail "$repo 未产出 .node"
  cp "$n" "$out_dir/$out_name"
  chmod +x "$out_dir/$out_name"
  notice "built $out_name (arch: $(file -b "$out_dir/$out_name"))"
}

# ── 先把插件构建到临时目录（此阶段不触碰 resources/app，失败也不会破坏已打包的 app.asar）──
rm -rf "$staging_dir"
build_addon "msojocs/skyline-shared-memory" "master" "" \
  "$staging_dir/sharedMemory" "sharedMemory.node"

build_addon "msojocs/skyline-client-server" "master" "packages/native" \
  "$staging_dir/skyline-addon/build" "skyline.node"

# ── 构建成功后再解包、注入、打包 ──
notice "unpack resources/app"
"$root_dir/tools/asar-helper.sh" unpack || fail "asar unpack"

mkdir -p "$package_dir/node_modules/sharedMemory" \
         "$package_dir/node_modules/skyline-addon/build"
cp "$staging_dir/sharedMemory/sharedMemory.node" "$package_dir/node_modules/sharedMemory/"
cp "$staging_dir/skyline-addon/build/skyline.node" "$package_dir/node_modules/skyline-addon/build/"

# ── JS 补丁（Electron 布局）──
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

notice "Skyline arm64 插件构建完成（如 skyline 仍需运行 skyline-server 镜像）"
exit 0
