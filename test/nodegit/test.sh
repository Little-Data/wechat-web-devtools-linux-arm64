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
    const repo = await nodegit.Repository.open('$root_dir');
    console.log('nodegit test success');
  } catch (err) {
    console.error('nodegit test failed', err);
    process.exit(1);
  }
})();
EOF