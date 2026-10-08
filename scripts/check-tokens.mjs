#!/usr/bin/env node
// 投资监控 ↔ 设计系统 的一致性门禁。
//
// 两条检查：
//   1) 仓库内的 Panel/DreamanualTheme.invest.swift 必须与 design/dist 的生成物逐字节相同
//      —— 防「改了 tokens.json 忘了拷进来」和「有人手改了生成物」。
//   2) 代码里引用的 dm* 令牌必须在生成物里有定义
//      —— 编译也能抓，但这条在改完令牌、还没来得及重编译时就能红，
//         而且 `swiftc -parse` 快得多（正式编译全量要一两分钟）。
//
// 用法：node scripts/check-tokens.mjs
// 同步：node scripts/check-tokens.mjs --sync

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, '..');
const local = path.join(appRoot, 'Panel/DreamanualTheme.invest.swift');
const generated = path.resolve(appRoot, '../../design/dist/swift/DreamanualTheme.invest.swift');
const THEME_NAME = 'DreamanualTheme.invest.swift';

if (process.argv.includes('--sync')) {
  fs.copyFileSync(generated, local);
  console.log(`已同步 ${path.relative(appRoot, local)}`);
  process.exit(0);
}

let failed = false;

// ---- 1) 生成物是否一致 ----
if (!fs.existsSync(generated)) {
  console.error(`✗ 找不到生成物：${generated}`);
  console.error('  先在 design/ 跑 node build.mjs');
  process.exit(1);
}
const localText = fs.readFileSync(local, 'utf8');
const generatedText = fs.readFileSync(generated, 'utf8');
if (localText !== generatedText) {
  console.error(`✗ 生成物不同步：Panel/${THEME_NAME} 与 design/dist 不一致`);
  console.error('  跑 node scripts/check-tokens.mjs --sync 同步');
  failed = true;
} else {
  console.log('✓ 生成物与 design/dist 逐字节一致');
}

// ---- 2) 代码引用的令牌是否都有定义 ----
// 生成物里的公开符号：常量（`static let dmBg`）与修饰器（`func dmShadowCard`）。
// 只收 `static let` 的话，新加的阴影修饰器会被当成「引用了没定义的令牌」。
const defined = new Set(
  [...generatedText.matchAll(/(?:static let|func)\s+(dm\w+)/g)].map((m) => m[1]),
);

const sources = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['.git', 'dist', '.workbuddy', '.temp'].includes(entry.name)) continue;
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p);
    else if (entry.name.endsWith('.swift') && entry.name !== THEME_NAME) {
      sources.push(p);
    }
  }
})(appRoot);

const missing = new Map();
for (const file of sources) {
  const src = fs.readFileSync(file, 'utf8');
  for (const m of src.matchAll(/\.(dm[A-Z]\w*)/g)) {
    if (!defined.has(m[1]) && !missing.has(m[1])) {
      missing.set(m[1], path.relative(appRoot, file));
    }
  }
}

if (missing.size) {
  console.error(`✗ 引用了生成物里没有的令牌：${missing.size} 个`);
  for (const [name, file] of missing) console.error(`   ${name}  ← ${file}`);
  failed = true;
} else {
  console.log(`✓ 令牌引用完整（生成物定义 ${defined.size} 个，扫描 ${sources.length} 个源文件）`);
}

process.exit(failed ? 1 : 0);
