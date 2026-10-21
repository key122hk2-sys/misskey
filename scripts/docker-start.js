// SPDX-FileCopyrightText: syuilo and misskey-project
// SPDX-License-Identifier: AGPL-3.0-only
//
// Docker distroless 環境用の起動スクリプト。
// pnpm run migrateandstart の代替として、Node.js のみで動作する。
'use strict';
const { spawnSync, spawn } = require('node:child_process');
const { existsSync } = require('node:fs');
const { resolve } = require('node:path');

const rootDir = resolve(__dirname, '..');
const backendDir = resolve(rootDir, 'packages/backend');
const node = process.execPath;

function run(args, opts) {
	const r = spawnSync(node, args, { stdio: 'inherit', env: process.env, ...opts });
	if (r.error) throw r.error;
	if (r.status !== 0) process.exit(r.status ?? 1);
}

// Step 1: YAML → JSON 変換
run(['scripts/compile_config.js'], { cwd: backendDir });

// Step 2: TypeORM マイグレーション
// node_modules/.bin/typeorm はシェルスクリプトなので cli.js を直接呼ぶ
// cwd=backendDir で ormconfig.js の migration/*.js 解決が正しく動く
const typeormCli = resolve(backendDir, 'node_modules/typeorm/cli.js');
if (!existsSync(typeormCli)) throw new Error(`typeorm CLI not found: ${typeormCli}`);
run([typeormCli, 'migration:run', '-d', './ormconfig.js'], { cwd: backendDir });

// Step 3: サーバー起動
// tini (ENTRYPOINT) がシグナル管理するので spawn で子プロセスへ転送する
const entryJs = resolve(backendDir, 'built/entry.js');
if (!existsSync(entryJs)) throw new Error(`entry.js not found: ${entryJs}`);
const child = spawn(node, [entryJs], { cwd: rootDir, stdio: 'inherit', env: process.env });
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
	process.on(sig, () => child.kill(sig));
}
child.on('exit', (code, signal) => {
	if (signal) process.kill(process.pid, signal);
	else process.exit(code ?? 0);
});
