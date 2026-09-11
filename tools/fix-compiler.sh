#! /bin/bash

set -e

warn() {
    echo -e "\033[43;37m 警告 \033[0m $1"
}
root_dir=$(cd `dirname $0`/.. && pwd -P)

srcdir=$root_dir
package_dir="$root_dir/resources/app"


$root_dir/tools/asar-helper.sh unpack

cd "$package_dir"

apply_prepend_patch() {
    local target_file="$1"
    local patch_file="$2"

    if [ ! -f "$target_file" ]; then
        echo -e "\e[1;31m$target_file is not exist\e[0m" >&2
        $root_dir/tools/asar-helper.sh pack
        exit 1
    fi

    if [ ! -f "$patch_file" ]; then
        echo -e "\e[1;31m$patch_file is not exist\e[0m" >&2
        $root_dir/tools/asar-helper.sh pack
        exit 1
    fi

    local patch_size=$(wc -c < "$patch_file")
    if cmp -s -n "$patch_size" "$patch_file" "$target_file"; then
        echo "$target_file is already patched"
        return
    fi

    local tmp_file=$(mktemp)
    cat "$patch_file" "$target_file" > "$tmp_file"
    cat "$tmp_file" > "$target_file"
    rm "$tmp_file"
}

apply_prepend_patch "$package_dir/js/electron/backend/bootstrap.js" "$root_dir/res/scripts/bootstrap.js"
apply_prepend_patch "$package_dir/js/common/miniprogram-builder/modules/corecompiler/original/workerThread/config.js" "$root_dir/res/scripts/config.js"

# 修复基础库 3.x 懒加载架构下 WAAutoService.js / WAAutoWebview.js 为空文件导致的
# net::ERR_EMPTY_RESPONSE（详见 tools/fix-vendor.js 注释）
node "$root_dir/tools/fix-vendor.js" "$package_dir"

echo "replace: wcc,wcsc linux version"
arch=$(node "$root_dir/tools/parse-config.js" --get-arch $@)

# 编译器产物由 wx-compiler-arm64 构建流程编译后注入 cache/compiler，
# 本脚本只负责替换进应用（不再从上游下载）。
compiler_cache="${srcdir}/cache/compiler"
for f in "wcc-${arch}" "wcsc-${arch}" "wcc-${arch}.node" "wcsc-${arch}.node"; do
  if [ ! -f "${compiler_cache}/${f}" ]; then
    echo -e "\e[1;31m缺少编译器产物: ${compiler_cache}/${f}\e[0m" >&2
    $root_dir/tools/asar-helper.sh pack
    exit 1
  fi
done

cp "${compiler_cache}/wcc-${arch}" "${package_dir}/node_modules/wcc-exec/wcc"
cp "${compiler_cache}/wcsc-${arch}" "${package_dir}/node_modules/wcc-exec/wcsc"
cd "${package_dir}/node_modules/wcc-exec" && chmod +x wcc wcsc && rm -rf wcc.exe wcsc.exe

# 修复：可视化用的wcc,wcsc
echo "fix: wcc,wcsc"
\cp "${compiler_cache}/wcc-${arch}.node" "${package_dir}/node_modules/wcc-electron/build/Release"
cd "${package_dir}/node_modules/wcc-electron/build/Release" && rm -rf wcc.node && mv wcc-${arch}.node wcc.node
\cp "${compiler_cache}/wcsc-${arch}.node" "${package_dir}/node_modules/wcc-electron/build/Release"
cd "${package_dir}/node_modules/wcc-electron/build/Release" && rm -rf wcsc.node && mv wcsc-${arch}.node wcsc.node

$root_dir/tools/asar-helper.sh pack