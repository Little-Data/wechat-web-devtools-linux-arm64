#!/usr/bin/env node
/**
 * 修复基础库 3.x（懒加载架构）下 WAAutoService.js / WAAutoWebview.js 为空文件
 * 导致的 “Failed to load resource: net::ERR_EMPTY_RESPONSE”。
 *
 * 背景：
 *   自基础库 3.x 起，基础库改为懒加载架构：WAService.js、WAAutoService.js、
 *   WAAutoWebview.js 等入口被替换成 0 字节占位文件（WAService.js 只剩几百字节的
 *   引导代码），真正的实现移到了 WAServiceMainContext.js / WASubContext.js /
 *   WAWebview.js 等文件里。
 *   而开发者工具（SimulatorCodeCoreService）仍无条件把 WAAutoService.js /
 *   WAAutoWebview.js 注入 appservice / pageframe，请求这些空文件时会报
 *   net::ERR_EMPTY_RESPONSE。
 *
 * 做法：
 *   当 libVersion >= 3（或为 latest/dev 这类非具体旧版本号）时，跳过注入这些
 *   空入口文件。旧基础库（< 3）仍保持原样，避免影响其自动化能力。
 *
 * 用法：
 *   node fix-vendor.js <resources/app 目录>
 */
"use strict";

const fs = require("fs");
const path = require("path");

const appDir = process.argv[2];
if (!appDir) {
  console.error("usage: fix-vendor.js <app-dir>");
  process.exit(1);
}

const replacements = [
  {
    name: "getAppServiceMainFrame: WAAutoService.js",
    from: 'r.push("WAAutoService.js"),r.push(i.AppServiceMainContextVendor);',
    to: '(parseFloat(e.libVersion)<3)&&r.push("WAAutoService.js"),r.push(i.AppServiceMainContextVendor);',
  },
  {
    name: "getAppServiceSubFrame: WAAutoService.js",
    from: 'p.unshift("WAAutoService.js");',
    to: '(parseFloat(e.libVersion)<3)&&p.unshift("WAAutoService.js");',
  },
  {
    name: "getPageFrame: WAAutoWebview.js",
    from: 'e.autoIsEnabled&&!e.externalDebugLib&&r.push("WAAutoWebview.js")',
    to: 'e.autoIsEnabled&&!e.externalDebugLib&&(parseFloat(e.libVersion)<3)&&r.push("WAAutoWebview.js")',
  },
];

const stats = {
  applied: 0,
  already: 0,
  matched: new Set(),
};

function walk(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    return;
  }
  for (const ent of entries) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p);
    else if (ent.isFile() && ent.name.endsWith(".js")) patchFile(p);
  }
}

function patchFile(file) {
  let src;
  try {
    src = fs.readFileSync(file, "utf8");
  } catch (e) {
    return;
  }
  let out = src;
  let changed = false;
  for (const r of replacements) {
    if (out.includes(r.to)) {
      stats.already++;
      stats.matched.add(r.name);
      continue;
    }
    if (out.includes(r.from)) {
      out = out.split(r.from).join(r.to);
      changed = true;
      stats.applied++;
      stats.matched.add(r.name);
      console.log("[fix-vendor] patched " + r.name + " in " + path.relative(appDir, file));
    }
  }
  if (changed) fs.writeFileSync(file, out);
}

walk(appDir);

console.log("[fix-vendor] applied=" + stats.applied + ", already=" + stats.already);
for (const r of replacements) {
  if (!stats.matched.has(r.name)) {
    console.warn("[fix-vendor] WARN: pattern not found -> " + r.name);
  }
}
