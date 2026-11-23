#!/usr/bin/env node
// Benchmarks moonja against ninja on a generated project, in the spirit of
// ninja's misc/write_fake_manifests.py: N "object files" with depfiles in
// D directories, linked into libraries and a final binary.
//
//   node scripts/bench.mjs --ninja PATH [--moonja "node .../cmd.js"] [--objects N] [--runs R]
//
// Times (median of R runs, milliseconds):
//   parse   -t targets all: load the manifest only
//   noop    a build with everything up to date: manifest, build and deps
//           logs, stat of every file, dirty checking
//   dryrun  -n in a clean copy: planning and status output for every edge

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..");
const opts = { ninja: process.env.NINJA || "ninja", moonja: null, objects: 5000, runs: 5 };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--ninja") opts.ninja = process.argv[++i];
  else if (a === "--moonja") opts.moonja = process.argv[++i];
  else if (a === "--objects") opts.objects = Number(process.argv[++i]);
  else if (a === "--runs") opts.runs = Number(process.argv[++i]);
}
opts.moonja ??= `node ${path.join(root, "_build", "js", "release", "build", "cmd", "cmd.js")}`;

const windows = process.platform === "win32";

// One object per source, each with a depfile naming a few headers.
function generate(dir, objects) {
  const perDir = 50;
  const lines = [
    "builddir = out",
    "rule cc",
    // The command writes the object and a depfile; it never runs in the
    // timed runs, only in the initial build.
    `  command = node gen.js cc $out $in`,
    "  depfile = $out.d",
    "  deps = gcc",
    "  description = CC $out",
    "rule ar",
    `  command = node gen.js ar $out $in`,
    "  description = AR $out",
    "rule link",
    `  command = node gen.js ar $out $in`,
    "  description = LINK $out",
    "",
  ];
  const libs = [];
  for (let d = 0; d * perDir < objects; d++) {
    const objs = [];
    fs.mkdirSync(path.join(dir, `src${d}`), { recursive: true });
    for (let h = 0; h < 5; h++) fs.writeFileSync(path.join(dir, `src${d}`, `h${h}.h`), `// ${d}/${h}\n`);
    for (let i = d * perDir; i < Math.min(objects, (d + 1) * perDir); i++) {
      fs.writeFileSync(path.join(dir, `src${d}`, `f${i}.c`), `int f${i};\n`);
      lines.push(`build out/obj/src${d}/f${i}.o: cc src${d}/f${i}.c`);
      lines.push(`  cflags = -O2 -DFILE=${i} -Isrc${d}`);
      objs.push(`out/obj/src${d}/f${i}.o`);
    }
    lines.push(`build out/lib/libsrc${d}.a: ar ${objs.join(" ")}`);
    libs.push(`out/lib/libsrc${d}.a`);
  }
  lines.push(`build out/app: link ${libs.join(" ")}`);
  lines.push("default out/app");
  fs.writeFileSync(path.join(dir, "build.ninja"), lines.join("\n") + "\n");
  fs.writeFileSync(
    path.join(dir, "gen.js"),
    `const fs = require("node:fs");
const [op, out, ...ins] = process.argv.slice(2);
fs.mkdirSync(require("node:path").dirname(out), { recursive: true });
fs.writeFileSync(out, "");
if (op === "cc") {
  const dir = ins[0].split("/")[0];
  const headers = [0, 1, 2, 3, 4].map((h) => dir + "/h" + h + ".h");
  fs.writeFileSync(out + ".d", out + ": " + [ins[0], ...headers].join(" ") + "\\n");
}
`,
  );
}

function run(tool, args, cwd) {
  const words = tool.split(" ");
  const start = process.hrtime.bigint();
  const r = spawnSync(words[0], [...words.slice(1), ...args], { cwd, encoding: "utf8", maxBuffer: 1 << 28 });
  const ms = Number(process.hrtime.bigint() - start) / 1e6;
  if (r.error) throw r.error;
  return { ms, code: r.status, out: r.stdout, err: r.stderr };
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "moonja-bench-"));
const built = path.join(work, "built");
const clean = path.join(work, "clean");
console.log(`generating ${opts.objects} objects in ${work}`);
generate(built, opts.objects);
fs.cpSync(built, clean, { recursive: true });
console.log("building once with ninja (not timed)...");
const first = run(opts.ninja, [], built);
if (first.code !== 0) {
  console.error(first.out.slice(-2000), first.err);
  process.exit(1);
}
const edges = opts.objects + Math.ceil(opts.objects / 50) + 1;
const manifestKiB = Math.round(fs.statSync(path.join(built, "build.ninja")).size / 1024);
console.log(`${edges} edges, build.ninja ${manifestKiB} KiB, Node ${process.version}, ${os.cpus()[0].model}\n`);

const scenarios = [
  ["parse", built, ["-t", "targets", "all"]],
  ["noop", built, []],
  ["dryrun", clean, ["-n"]],
];
const rows = [];
for (const [name, dir, args] of scenarios) {
  const times = { ninja: [], moonja: [] };
  for (let i = 0; i < opts.runs; i++) {
    for (const who of ["ninja", "moonja"]) {
      const r = run(opts[who], args, dir);
      if (r.code !== 0) {
        console.error(`${who} ${name} failed:\n${r.err}`);
        process.exit(1);
      }
      if (name === "noop" && !r.out.includes("no work to do")) {
        console.error(`${who} noop did work:\n${r.out.slice(0, 500)}`);
        process.exit(1);
      }
      times[who].push(r.ms);
    }
  }
  const n = median(times.ninja);
  const m = median(times.moonja);
  rows.push({ name, ninja: n, moonja: m });
}
console.log("scenario   ninja (ms)   moonja (ms)   ratio");
for (const r of rows) {
  console.log(
    `${r.name.padEnd(9)}  ${r.ninja.toFixed(0).padStart(10)}   ${r.moonja.toFixed(0).padStart(11)}   ${(r.moonja / r.ninja).toFixed(1).padStart(5)}x`,
  );
}
// On GitHub Actions, also report the numbers as a job summary table and as
// notice annotations (readable without signing in, unlike the job log).
if (process.env.GITHUB_ACTIONS) {
  const env = `${os.platform()}, Node ${process.version}, ${os.cpus().length} x ${os.cpus()[0].model}`;
  for (const r of rows) {
    console.log(
      `::notice title=bench ${r.name}::ninja ${r.ninja.toFixed(0)} ms, moonja ${r.moonja.toFixed(0)} ms, ${(r.moonja / r.ninja).toFixed(1)}x (${edges} edges; ${env})`,
    );
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    const table = [
      `${edges} edges, build.ninja ${manifestKiB} KiB, median of ${opts.runs} runs; ${env}`,
      "",
      "| scenario | ninja (ms) | moonja (ms) | ratio |",
      "| --- | ---: | ---: | ---: |",
      ...rows.map((r) => `| ${r.name} | ${r.ninja.toFixed(0)} | ${r.moonja.toFixed(0)} | ${(r.moonja / r.ninja).toFixed(1)}x |`),
      "",
    ];
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, table.join("\n"));
  }
}
fs.rmSync(work, { recursive: true, force: true });
