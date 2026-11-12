import { fileURLToPath } from 'node:url';
import { workerData } from 'node:worker_threads';

const { args, cwd, entry } = workerData;
const executable = fileURLToPath(entry);

// Node Workers cannot change the process working directory. npm receives its
// own prefix and also reads process.cwd() during configuration.
process.cwd = () => cwd;

// DSH speaks pnpm's CLI vocabulary. Preserve the package lock on repair and
// use the same install/remove/inspect contract with the embedded npm CLI.
const [operation, ...rest] = args;
const command = operation === 'add' ? 'install'
  : operation === 'remove' ? 'uninstall'
  : operation === 'install' && rest.includes('--frozen-lockfile') ? 'ci' : operation;
const flags = rest.filter(arg => arg !== '--frozen-lockfile').map(arg =>
  arg === '--config.lockfile=false' ? '--package-lock=false' : arg.replace(/^--config\./, '--'));
process.argv = [process.execPath, executable, '--prefix', cwd, command, ...flags,
  '--ignore-scripts', '--no-audit', '--no-fund', '--no-update-notifier', '--strict-ssl',
];
await import(entry);
