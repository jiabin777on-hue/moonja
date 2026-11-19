// Portable build commands for the differential tests:
//   node t.js cp SRC DST          copy
//   node t.js cat DST SRC...      concatenate
//   node t.js echo TEXT...        print to stdout
//   node t.js warn TEXT...        print to stderr
//   node t.js fail CODE [TEXT]    print TEXT and exit with CODE
//   node t.js cc OUT DEPFILE SRC [HEADER...]
//                                 "compile": OUT gets SRC and the headers,
//                                 DEPFILE lists them in Makefile syntax
//   node t.js restat DST SRC      copy only if the contents changed
//   node t.js write DST TEXT...   write TEXT to DST
//   node t.js rsp DST RSPFILE     copy the response file into DST
//   node t.js msvc OUT SRC HEADER...
//                                 like cl /showIncludes
//   node t.js multi TEXT... -- OUT...
//                                 write TEXT to every OUT
//   node t.js dyndep DD OUT INPUT...
//                                 write a dyndep file making OUT depend on
//                                 the INPUTs
const fs = require("node:fs");
const [op, ...args] = process.argv.slice(2);
const read = (f) => fs.readFileSync(f, "utf8");
switch (op) {
  case "cp":
    fs.writeFileSync(args[1], read(args[0]));
    break;
  case "cat":
    fs.writeFileSync(args[0], args.slice(1).map(read).join(""));
    break;
  case "echo":
    process.stdout.write(args.join(" ") + "\n");
    break;
  case "warn":
    process.stderr.write(args.join(" ") + "\n");
    break;
  case "fail":
    if (args.length > 1) process.stdout.write(args.slice(1).join(" ") + "\n");
    process.exitCode = Number(args[0]);
    break;
  case "cc": {
    const [out, depfile, ...srcs] = args;
    fs.writeFileSync(out, srcs.map(read).join(""));
    fs.writeFileSync(depfile, `${out}: ${srcs.join(" ")}\n`);
    break;
  }
  case "restat": {
    const text = read(args[1]);
    if (!fs.existsSync(args[0]) || read(args[0]) !== text) fs.writeFileSync(args[0], text);
    break;
  }
  case "write":
    fs.writeFileSync(args[0], args.slice(1).join(" ") + "\n");
    break;
  case "rsp":
    fs.writeFileSync(args[0], read(args[1].replace(/^@/, "")));
    break;
  case "dyndep": {
    const [dd, out, ...inputs] = args;
    fs.writeFileSync(dd, `ninja_dyndep_version = 1\nbuild ${out}: dyndep | ${inputs.join(" ")}\n`);
    break;
  }
  case "msvc": {
    // "cl /showIncludes": echoes the source name, lists headers by
    // absolute path, then writes OUT.
    const [out, src, ...headers] = args;
    const path = require("node:path");
    process.stdout.write(path.basename(src) + "\r\n");
    for (const h of headers) process.stdout.write(`Note: including file: ${path.resolve(h)}\r\n`);
    process.stdout.write("warning: kept\r\n");
    fs.writeFileSync(out, [src, ...headers].map(read).join(""));
    break;
  }
  case "multi": {
    // Writes every output named after "--".
    const outs = args.slice(args.indexOf("--") + 1);
    for (const o of outs) fs.writeFileSync(o, args.slice(0, args.indexOf("--")).join(" ") + "\n");
    break;
  }
  default:
    process.stderr.write(`t.js: unknown op ${op}\n`);
    process.exitCode = 2;
}
