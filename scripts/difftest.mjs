#!/usr/bin/env node
// Differential tests: runs every case in tests/diff with real ninja and
// with moonja, step by step in two fresh copies, and requires identical
// stdout, stderr, exit codes, output files and build log entries.
//
//   node scripts/difftest.mjs --ninja PATH [--moonja "node _build/.../cmd.js"] [case...]
//
// A case is a directory holding a build.ninja, its inputs and steps.txt:
//
//   run ARGS...        run the build tool (arguments split on spaces;
//                      "double quotes" group)
//   touch FILE         give FILE a new mtime (after a short pause)
//   write FILE TEXT... replace FILE's contents (after a short pause)
//   rm FILE            delete FILE
//   sleep MS           pause
//   # comment
//
// Arguments and file names may spell bytes as \xHH (POSIX only), and a
// file named `platform` holding "posix" or "win32" limits a case to it.
// Outputs, files and logs are compared as bytes.
//
// Commands in the manifests run `node t.js ...` (tests/diff/t.js is copied
// into every case), so one manifest works with /bin/sh and CreateProcess.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..");
const casesDir = path.join(root, "tests", "diff");

function parseArgs(argv) {
  const opts = { ninja: process.env.NINJA || "ninja", moonja: null, cases: [], keep: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--ninja") opts.ninja = argv[++i];
    else if (a === "--moonja") opts.moonja = argv[++i];
    else if (a === "--keep") opts.keep = true;
    else opts.cases.push(a);
  }
  if (opts.moonja === null) {
    opts.moonja = `node ${path.join(root, "_build", "js", "debug", "build", "cmd", "cmd.js")}`;
  }
  return opts;
}

function splitWords(line) {
  const words = [];
  const re = /"([^"]*)"|(\S+)/g;
  let m;
  while ((m = re.exec(line)) !== null) words.push(m[1] !== undefined ? m[1] : m[2]);
  return words;
}

function pause(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Makes outputs comparable: the program name getopt prints, and the
// version string of the Kitware build of ninja.
function normalize(text, cwd) {
  // -t graph names vertices by address: number them by first appearance.
  const names = new Map();
  const vertex = (m, addr) => {
    if (!names.has(addr)) names.set(addr, `P${names.size + 1}`);
    return `"${names.get(addr)}"`;
  };
  // -t compdb prints the working directory, which differs per copy.
  const dirs = [cwd, cwd.replaceAll("\\", "\\\\"), cwd.replaceAll("\\", "/")];
  for (const d of dirs) text = text.split(d).join("<DIR>");
  return text
    .replace(/"(0x[0-9a-f]+|[0-9A-F]{16})"/g, vertex)
    .replace(/^[^\s]*?ninja(\.exe)?:/gm, "ninja:")
    .replace(/^[^\s]*?cmd\.js:/gm, "ninja:")
    .replace(/1\.13\.2\.git\.kitware\.jobserver-pipe-1/g, "1.13.2")
    // -d explain prints mtimes, which differ between the two copies.
    .replace(/\((-?\d+) vs (-?\d+)\)/g, "(T vs T)")
    .replace(/(mtime|stored mtime) (-?\d+)/g, "$1 T");
}

// Outputs, files and logs are compared byte for byte: each byte is one
// char ("latin1"), and turned back into UTF-8 only to print a difference.
const bin = (buf) => buf.toString("latin1");
const show = (s) => Buffer.from(s, "latin1").toString("utf8");

// A step argument may spell bytes as \xHH, for names that are not UTF-8.
const hasBytes = (s) => /\\x[0-9a-fA-F]{2}/.test(s);
function argBytes(s) {
  const parts = s.split(/(\\x[0-9a-fA-F]{2})/);
  return Buffer.concat(parts.map((p) => (/^\\x/.test(p) ? Buffer.from([parseInt(p.slice(2), 16)]) : Buffer.from(p))));
}
// A path under dir; a Buffer on POSIX when it holds bytes.
function stepPath(dir, s) {
  if (!hasBytes(s)) return path.join(dir, s);
  if (process.platform === "win32") throw new Error(`byte paths need POSIX: ${s}`);
  return Buffer.concat([Buffer.from(dir + path.sep), argBytes(s)]);
}

function run(tool, args, cwd) {
  const words = splitWords(tool);
  const options = {
    cwd,
    env: { ...process.env, NINJA_STATUS: process.env.NINJA_STATUS ?? "[%f/%t] " },
  };
  let r;
  if (args.some(hasBytes)) {
    // Node passes arguments as UTF-8, so the shell builds the bytes.
    const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
    const octal = (s) => [...argBytes(s)].map((b) => `\\0${b.toString(8).padStart(3, "0")}`).join("");
    const script = [...words.map(quote), ...args.map((a) => `"$(printf '%b' '${octal(a)}')"`)].join(" ");
    r = spawnSync("/bin/sh", ["-c", script], options);
  } else {
    r = spawnSync(words[0], [...words.slice(1), ...args], options);
  }
  if (r.error) throw r.error;
  const dir = bin(Buffer.from(cwd));
  return { out: normalize(bin(r.stdout), dir), err: normalize(bin(r.stderr), dir), code: r.status };
}

function copyDir(from, to) {
  fs.cpSync(from, to, { recursive: true });
  fs.copyFileSync(path.join(casesDir, "t.js"), path.join(to, "t.js"));
}

// Every file under dir (but the logs), with its contents.
function snapshot(dir) {
  const files = {};
  // Names are read as bytes too: on POSIX they need not be UTF-8.
  const walk = (d, rel) => {
    const entries = fs.readdirSync(d, { withFileTypes: true, encoding: "buffer" })
      .map((e) => ({ e, name: bin(e.name) }))
      .sort((a, b) => (a.name < b.name ? -1 : 1));
    for (const { e, name } of entries) {
      const r = rel ? `${rel}/${name}` : name;
      const p = Buffer.concat([d, Buffer.from(path.sep), e.name]);
      if (e.isDirectory()) {
        files[r + "/"] = "";
        walk(p, r);
      } else if (name !== ".ninja_log" && name !== ".ninja_deps" && name !== "steps.txt") {
        files[r] = bin(fs.readFileSync(p));
      }
    }
  };
  walk(Buffer.from(dir), "");
  return files;
}

// The build log's (output, command hash) pairs; times and mtimes differ
// between two runs.
function logEntries(dir) {
  const found = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === ".ninja_log") {
        const lines = bin(fs.readFileSync(p)).split("\n");
        found.push(lines[0]);
        for (const line of lines.slice(1)) {
          const f = line.split("\t");
          if (f.length === 5) found.push(`${f[3]} ${f[4]}`);
        }
      }
    }
  };
  walk(dir);
  return found.sort().join("\n");
}

function diffText(name, a, b) {
  if (a === b) return null;
  const al = a.split("\n");
  const bl = b.split("\n");
  const lines = [`  ${name} differs:`];
  for (let i = 0; i < Math.max(al.length, bl.length); i++) {
    if (al[i] !== bl[i]) {
      lines.push(`    line ${i + 1}`);
      lines.push(`      ninja : ${JSON.stringify(show(al[i] ?? ""))}`);
      lines.push(`      moonja: ${JSON.stringify(show(bl[i] ?? ""))}`);
      if (lines.length > 30) break;
    }
  }
  return lines.join("\n");
}

function runCase(name, opts) {
  const caseDir = path.join(casesDir, name);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), `moonja-diff-${name}-`));
  const dirs = { ninja: path.join(work, "ninja"), moonja: path.join(work, "moonja") };
  copyDir(caseDir, dirs.ninja);
  copyDir(caseDir, dirs.moonja);
  const tools = { ninja: opts.ninja, moonja: opts.moonja };
  const problems = [];
  let runs = 0;
  const steps = fs.readFileSync(path.join(caseDir, "steps.txt"), "utf8").split(/\r?\n/);
  for (const [index, raw] of steps.entries()) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const [op, ...rest] = splitWords(line);
    const where = `step ${index + 1} (${line})`;
    if (op === "run") {
      runs++;
      const results = {};
      for (const who of ["ninja", "moonja"]) results[who] = run(tools[who], rest, dirs[who]);
      const a = results.ninja;
      const b = results.moonja;
      for (const d of [diffText("stdout", a.out, b.out), diffText("stderr", a.err, b.err)]) {
        if (d) problems.push(`${where}\n${d}`);
      }
      if (a.code !== b.code) problems.push(`${where}\n  exit code: ninja ${a.code}, moonja ${b.code}`);
    } else {
      for (const who of ["ninja", "moonja"]) {
        const target = rest[0] === undefined ? null : stepPath(dirs[who], rest[0]);
        if (op === "touch") {
          pause(20);
          const now = new Date();
          if (!fs.existsSync(target)) fs.writeFileSync(target, "");
          fs.utimesSync(target, now, now);
        } else if (op === "write") {
          pause(20);
          if (typeof target === "string") fs.mkdirSync(path.dirname(target), { recursive: true });
          fs.writeFileSync(target, rest.slice(1).join(" ") + "\n");
        } else if (op === "rm") {
          fs.rmSync(target, { force: true, recursive: true });
        } else if (op === "sleep") {
          // Paused once below, not per tool.
        } else {
          throw new Error(`${name}: ${where}: unknown step '${op}'`);
        }
      }
      if (op === "sleep") pause(Number(rest[0]));
    }
  }
  const files = { ninja: snapshot(dirs.ninja), moonja: snapshot(dirs.moonja) };
  const fileProblems = [];
  for (const f of new Set([...Object.keys(files.ninja), ...Object.keys(files.moonja)])) {
    const a = files.ninja[f];
    const b = files.moonja[f];
    if (a === undefined) fileProblems.push(`    only moonja has ${show(f)}`);
    else if (b === undefined) fileProblems.push(`    only ninja has ${show(f)}`);
    else if (a !== b) fileProblems.push(`    ${show(f)}: ninja ${JSON.stringify(show(a))}, moonja ${JSON.stringify(show(b))}`);
  }
  if (fileProblems.length > 0) problems.push(`after all steps\n  files differ:\n${fileProblems.join("\n")}`);
  const d2 = diffText(".ninja_log entries", logEntries(dirs.ninja), logEntries(dirs.moonja));
  if (d2) problems.push(`after all steps\n${d2}`);
  if (!opts.keep) fs.rmSync(work, { recursive: true, force: true });
  return { runs, problems, work };
}

const opts = parseArgs(process.argv.slice(2));
const names = opts.cases.length > 0
  ? opts.cases
  : fs.readdirSync(casesDir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort();
let failed = 0;
let skipped = 0;
let totalRuns = 0;
for (const name of names) {
  // A case may name the one platform it is for: "posix" or "win32".
  const only = path.join(casesDir, name, "platform");
  if (fs.existsSync(only)) {
    const want = fs.readFileSync(only, "utf8").trim();
    if (want !== (process.platform === "win32" ? "win32" : "posix")) {
      skipped++;
      console.log(`skip ${name} (${want} only)`);
      continue;
    }
  }
  const { runs, problems, work } = runCase(name, opts);
  totalRuns += runs;
  if (problems.length === 0) {
    console.log(`ok   ${name} (${runs} runs)`);
  } else {
    failed++;
    console.log(`FAIL ${name}`);
    for (const p of problems) console.log(p);
    if (opts.keep) console.log(`  kept in ${work}`);
  }
}
const ran = names.length - skipped;
console.log(`\n${ran - failed}/${ran} cases identical, ${totalRuns} runs compared`);
process.exit(failed === 0 ? 0 : 1);
