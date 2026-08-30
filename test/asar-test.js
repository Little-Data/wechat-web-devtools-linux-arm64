const fs = require('fs')
const path = require('path')
fs.readFileSync(path.join(__dirname, '../resources/app.asar/package.json'), 'utf8')