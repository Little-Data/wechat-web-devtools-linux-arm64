#!/bin/bash
set -ex

root_dir=$(cd `dirname $0`/../.. && pwd -P)
export PATH="$root_dir/node/bin:$PATH"

export JOBS=$(nproc)
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
