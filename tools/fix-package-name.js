#!/usr/bin/env node
const path = require("path");
const fs = require("fs");

const parseFile = function (path) {

    if (!fs.existsSync(path)) {
        console.error(`${path}文件不存在`)
        return;
    }
    let content = JSON.parse(fs.readFileSync(path, "utf8"));

    content.name = content.productName = "wechat-devtools";
    fs.writeFileSync(path, JSON.stringify(content));

};

let basedir = __dirname;
if(undefined !== process.env['srcdir'])
    basedir = process.env['srcdir'] + '/tools';
for (const packageDir of ["app", "app.asar.unpacked"]) {
    parseFile(path.resolve(basedir, `../resources/${packageDir}/package.json`));
    // parseFile(path.resolve(basedir, `../resources/${packageDir}/package-lock.json`));
}
