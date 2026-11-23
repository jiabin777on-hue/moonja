#!/usr/bin/env node
// Runs a build tool, waits until every MARKER file exists (written by
// `node t.js hang` once its command is running), sends SIGNAL to the tool
// and passes its stdout, stderr and exit code through. Used by the
// `interrupt` step of scripts/difftest.mjs (POSIX only).
//
//   node scripts/interrupt.mjs SIGNAL MARKER[,MARKER...] TOOL ARGS...
//
// Each marker holds the pid of the command that wrote it. After the tool
// exits, a command still alive means the tool left it running: that is
// reported on stderr, so the difference shows up in the comparison.

import fs from "node:fs";
import { spawn } from "node:child_process";

const [signal, markerList, tool, ...args] = process.argv.slice(2);
const markers = markerList.split(",");
const child = spawn(tool, args, { stdio: ["ignore", "pipe", "pipe"] });
const out = [];
const err = [];
child.stdout.on("data", (b) => out.push(b));
child.stderr.on("data", (b) => err.push(b));

const deadline = Date.now() + 30000;
const poll = setInterval(() => {
  if (markers.every((m) => fs.existsSync(m) && fs.readFileSync(m, "utf8").trim() !== "")) {
    clearInterval(poll);
    child.kill(signal);
  } else if (Date.now() > deadline) {
    clearInterval(poll);
    err.push(Buffer.from("interrupt.mjs: the commands never started\n"));
    child.kill("SIGKILL");
  }
}, 20);

child.on("close", (code, sig) => {
  clearInterval(poll);
  // Give the killed commands a moment to go away.
  setTimeout(() => {
    for (const m of markers) {
      if (!fs.existsSync(m)) continue;
      const pid = Number(fs.readFileSync(m, "utf8").trim());
      let alive = false;
      try {
        process.kill(pid, 0);
        alive = true;
      } catch {}
      if (alive) {
        err.push(Buffer.from(`interrupt.mjs: the command that wrote ${m} is still running\n`));
        try {
          process.kill(pid, "SIGKILL");
        } catch {}
      }
    }
    process.stdout.write(Buffer.concat(out));
    process.stderr.write(Buffer.concat(err));
    // A tool killed by the signal (no handler) is reported, not hidden.
    if (sig) process.stderr.write(`interrupt.mjs: the tool died of ${sig}\n`);
    process.exitCode = code ?? 255;
  }, 300);
});
