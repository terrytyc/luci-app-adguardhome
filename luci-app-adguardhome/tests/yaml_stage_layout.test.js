'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const packageRoot = path.resolve(__dirname, '..');
const initPath = path.join(packageRoot, 'root/etc/init.d/AdGuardHome');
const source = fs.readFileSync(initPath, 'utf8');
const start = source.indexOf('validate_yaml_stage() {');
const end = source.indexOf('\nactive_config_hash() (', start);

assert.notEqual(start, -1, 'missing validate_yaml_stage()');
assert.notEqual(end, -1, 'missing validate_yaml_stage() boundary');

const validateStage = source.slice(start, end);

assert.ok(validateStage.includes('config_dir="${config_file%/*}"'),
	'YAML staging must derive its namespace from the persistent config path');
assert.ok(validateStage.includes('[ "$stage" = "${config_file}.luci-${token}" ] || return 1'),
	'YAML staging must bind the exact tokenized path beside config_file');
assert.ok(validateStage.includes('path_contains_symlink "$config_dir" && return 1'),
	'YAML staging must reject symlinks in the persistent config directory');
assert.ok(!validateStage.includes('${stage%/*}" = "$work_dir'),
	'YAML staging must not require the persistent file to live in the RAM workdir');
assert.ok(!validateStage.includes('path_contains_symlink "$work_dir"'),
	'YAML staging must not validate the unrelated RAM data path as its namespace');

console.log('persistent YAML staging layout contract tests passed');
