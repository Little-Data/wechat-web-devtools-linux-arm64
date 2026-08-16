#!/bin/bash
root_dir=$(cd `dirname $0`/../.. && pwd -P)

export ELECTRON_RUN_AS_NODE=1
cd $root_dir
$root_dir/electron/electron <<EOF
const path = require('path');
console.info('__dirname', __dirname);
const p = path.join('$root_dir', 'resources/app/node_modules/nodegit/build/Release/nodegit.node')
console.info('nodegit path', p);
const nodegit = require(p);
(async () => {
  try {
    console.info('nodegit version', nodegit.version);
    console.info('open repo...')
    // 直接 require .node 拿到的是原始 addon，未经 lib/nodegit.js 的 promisify 包装，
    // 所以这里必须用 callback 形式调用
    const repo = await new Promise((resolve, reject) => {
      nodegit.Repository.open('$root_dir', (err, repo) => err ? reject(err) : resolve(repo));
    });
    console.log('nodegit test success', !!repo);
  } catch (err) {
    console.error('nodegit test failed', err);
    process.exit(1);
  }
})();
EOF