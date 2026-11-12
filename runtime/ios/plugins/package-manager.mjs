import { existsSync } from 'node:fs';
import { Worker } from 'node:worker_threads';
import { workerEnvironment } from '../process/worker-env.mjs';

const workerEntry = new URL('./package-worker.mjs', import.meta.url);
const npmEntry = new URL('./npm/bin/npm-cli.js', import.meta.url);
const maxOutputBytes = 4 * 1024 * 1024;
const registrySpec = /^(?:@[a-z\d][a-z\d._-]*\/)?[a-z\d][a-z\d._-]*(?:@[a-z\d*^~<>=|.+ -]+)?$/i;

export const packageManagerAvailable = existsSync(workerEntry) && existsSync(npmEntry);
export const registryOnlyMessage = 'iOS 本机仅支持从 npm 注册表安装插件。';

// Only the plugin manager uses this adapter. The engine's OS subprocess boundary
// stays in force for both plugins and their dependencies.
export function runPackageManager(command, args, options) {
  if (!packageManagerAvailable || command !== 'pnpm') throw new Error('iOS 插件包管理器不可用');
  const [operation, spec, key] = args;
  const valid = (operation === 'config' && spec === 'get' && key === 'registry') ||
    (['add', 'remove', 'view'].includes(operation) && typeof spec === 'string' && registrySpec.test(spec)) ||
    (operation === 'install' && args.slice(1).every(arg => arg.startsWith('--')));
  if (!valid) throw new Error(registryOnlyMessage);

  const { buffer = true, cancelSignal, timeout } = options;
  const worker = new Worker(workerEntry, {
    env: { ...workerEnvironment(options.env), CI: 'true' },
    workerData: { args, cwd: options.cwd, entry: npmEntry.href },
    stdout: true,
    stderr: true,
  });
  const stop = () => { void worker.terminate(); };
  const onAbort = () => stop();
  cancelSignal?.addEventListener('abort', onAbort, { once: true });
  if (cancelSignal?.aborted) stop();
  let timedOut = false;
  const timer = timeout === undefined ? undefined : setTimeout(() => {
    timedOut = true;
    stop();
  }, timeout);
  let workerError;
  worker.on('error', error => { workerError = error; });
  const exited = new Promise(resolve => worker.once('exit', resolve));
  const stdout = options.stdout === 'inherit' ? null : worker.stdout;
  const stderr = options.stderr === 'inherit' ? null : worker.stderr;
  if (stdout === null) worker.stdout.pipe(process.stdout, { end: false });
  if (stderr === null) worker.stderr.pipe(process.stderr, { end: false });
  const output = buffer ? Promise.all([readOutput(stdout), readOutput(stderr)]) : Promise.resolve(['', '']);
  const completion = Promise.all([exited, output]).then(([status, [out, err]]) => {
    const isCanceled = cancelSignal?.aborted === true;
    const exitCode = timedOut || isCanceled || workerError ? undefined : status;
    return {
      exitCode, stdout: out, stderr: err, timedOut, isCanceled,
      failed: exitCode !== 0, code: workerError?.code,
      shortMessage: workerError?.message || err.trim() || (exitCode === 0 ? undefined : 'iOS 插件包管理操作未完成'),
    };
  }).finally(() => {
    clearTimeout(timer);
    cancelSignal?.removeEventListener('abort', onAbort);
  });
  // Match the small part of Execa's contract used by DSH's existing manager.
  // There is no process ID and cancellation waits for the Worker to exit.
  return Object.assign(completion, { nodeChildProcess: worker, stdout, stderr, kill: stop });
}

async function readOutput(stream) {
  if (!stream) return '';
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    if (size + chunk.length <= maxOutputBytes) chunks.push(chunk);
    size += chunk.length;
  }
  if (size > maxOutputBytes) throw new Error('iOS 插件包管理输出过大');
  return Buffer.concat(chunks).toString('utf8');
}
