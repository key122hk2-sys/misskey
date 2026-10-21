// SPDX-FileCopyrightText: syuilo and misskey-project
// SPDX-License-Identifier: AGPL-3.0-only
//
// Docker distroless 環境用のヘルスチェックスクリプト。
// healthcheck.sh (bash + awk + curl) の代替として Node.js のみで動作する。
// TCP ポート / UNIX ドメインソケット (config.socket) の両方に対応する。
'use strict';
const { request } = require('node:http');
const { readFileSync } = require('node:fs');

const opts = { path: '/healthz', method: 'GET', timeout: 5000 };
let cfg = {};
try {
	cfg = JSON.parse(readFileSync('/misskey/built/.config.json', 'utf-8'));
} catch {}

if (typeof cfg.socket === 'string' && cfg.socket.length > 0) {
	opts.socketPath = cfg.socket;
} else {
	opts.hostname = '127.0.0.1';
	opts.port = (typeof cfg.port === 'number' && cfg.port)
		|| parseInt(process.env.PORT ?? '', 10)
		|| 3000;
}

const req = request(opts, (res) => {
	res.resume();
	process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on('error', () => process.exit(1));
req.on('timeout', () => { req.destroy(); process.exit(1); });
req.end();
