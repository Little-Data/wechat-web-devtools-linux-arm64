#!/bin/bash
set -ex

root_dir=$(cd `dirname $0`/../.. && pwd -P)
export PATH="$root_dir/node/bin:$PATH"

export JOBS=$(nproc)
# arch 必须显式传给 node-gyp：留空时 config.gypi 里 target_arch 为 ""，
# 而 common.gypi 的 `target_arch in "arm ia32 mips mipsel ppc"` 是 Python 子串判断，
# 空串会误命中，导致 v8_enable_pointer_compression / v8_enable_sandbox 被置 0，
# 编译出的 .node 缺失 V8_COMPRESS_POINTERS / V8_ENABLE_SANDBOX 等宏，调用时段错误
arch=${arch:-$(node "$root_dir/tools/parse-config.js" --get-arch "$@")}
configure_args=(
  --target_platform=linux
  --target_arch="$arch"
  --verbose
  --registry=https://registry.npmmirror.com
)
mkdir -p "$root_dir/tmp/node_test"
cd "$root_dir/tmp/node_test"

echo "simple install nodegit"
npm install nodegit@0.28.0-alpha.36
cd node_modules/nodegit
echo "rebuild nodegit"
HOME=~/.electron-gyp node-gyp configure "${configure_args[@]}" --target="36.6.0" --dist-url=https://electronjs.org/headers
HOME=~/.electron-gyp node-gyp build
rm -rf "$root_dir/resources/app.asar.unpacked/node_modules/nodegit/build/Release/nodegit.node"
cp -r "$root_dir/tmp/node_test/node_modules/nodegit/build/Release/nodegit.node" "$root_dir/resources/app.asar.unpacked/node_modules/nodegit/build/Release/nodegit.node"
cp -r "$root_dir/tmp/node_test/node_modules/nodegit/build/Release/nodegit.node" "$root_dir/resources/app/node_modules/nodegit/build/Release/nodegit.node"
