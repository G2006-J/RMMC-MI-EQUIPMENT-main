import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const nextCli = path.join(projectDir, "node_modules", "next", "dist", "bin", "next");
const projectNodeModules = path.join(projectDir, "node_modules");
const [command, ...args] = process.argv.slice(2);
const nextCommand = command || "dev";
const nextArgs = [...args];

if (["dev", "start"].includes(nextCommand) && !nextArgs.some((arg) => ["-p", "--port"].includes(arg))) {
  nextArgs.push("-p", process.env.PORT || "5501");
}

process.env.NODE_PATH = [projectNodeModules, process.env.NODE_PATH]
  .filter(Boolean)
  .join(path.delimiter);

const nextProcess = spawn(
  process.execPath,
  [nextCli, nextCommand, ...nextArgs],
  { cwd: projectDir, env: process.env, stdio: "inherit" },
);

nextProcess.on("error", (error) => {
  console.error("Failed to start the Next.js development server:", error);
  process.exitCode = 1;
});

nextProcess.on("exit", (code, signal) => {
  process.exitCode = signal ? 1 : code ?? 1;
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => nextProcess.kill(signal));
}
