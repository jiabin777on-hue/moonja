# moonja

> A drop-in replacement for [Ninja](https://ninja-build.org/) 1.13.2, written in MoonBit. It is verified by porting ninja's own unit tests and by differential testing against the real ninja binary.

用 MoonBit 实现、可直接替换 Ninja 的构建工具。兼容目标固定为 **ninja v1.13.2**，验证手段有两条：

1. 把 ninja 自带的 C++ 单元测试逐个移植成 MoonBit 测试。
2. 在同一份 `build.ninja` 上同时运行真实 ninja 和 moonja，要求 stdout、stderr、退出码、产出文件和 `.ninja_log` 逐字节一致。

```console
$ moon build --target js --release
$ node _build/js/release/build/cmd/cmd.js -C path/to/project
[1/3] CC foo.o
[2/3] CC bar.o
[3/3] LINK app
```

需要 Node.js 22.3 或更新版本。核心库不依赖任何 I/O，在 js、wasm-gc、native 三个后端上都通过全部测试。

## 支持什么

- **清单语言**：变量与作用域、`rule`/`build`/`pool`/`default`、`include`/`subninja`、`$` 转义、`ninja_required_version`、phony、隐式与 order-only 依赖、隐式输出、validation（`|@`）。
- **增量构建**：mtime 比较、命令哈希（rapidhash，与 ninja 的 `.ninja_log` v7 互通）、`restat`、`generator`、清单自重建（最多 100 轮）。
- **依赖发现**：`depfile`、`deps = gcc` / `deps = msvc` 写入 `.ninja_deps` v4 二进制日志、dyndep 文件。
- **调度**：`-j` 并行、`-k` 容错、`-l` 负载限制、pool 与 console pool、关键路径优先。
- **输出**：`$NINJA_STATUS` 全部占位符（含 ETA 预测）、智能终端单行刷新与中间省略、失败报告、颜色剥离、`-v`、`--quiet`、`-d explain`。
- **命令行**：`-C -f -j -k -l -n -v -d -t -w --version --quiet`。参数解析模拟 glibc `getopt_long`（Linux）和 ninja 自带的 getopt（Windows），报错文本也一致。
- **子工具**：`clean`（`-g` `-r`）、`cleandead`、`commands`、`inputs`、`multi-inputs`、`deps`、`missingdeps`、`graph`、`query`、`targets`、`compdb`（`-x`）、`compdb-targets`、`recompact`、`restat`、`rules`、`urtle`、`wincodepage`。
- **平台细节**：
  - mtime 单位与 ninja 相同：POSIX 下是纳秒，Windows 下是以 2000 年为纪元的 FILETIME 刻度。因此 moonja 和 ninja 可以共用同一个构建目录。
  - POSIX 下用 `/bin/sh -c` 运行命令，非 console 命令放进独立进程组。
  - Windows 下按 CreateProcess 规则解析命令行。ninja 自己的输出走文本模式 CRLF，命令输出原样透传，与 ninja 的 #773 修复一致。
  - 命令退出码原样透传为 moonja 的退出码，中断时为 130。

## 怎么验证的

### 1. 移植 ninja 自己的测试（全部通过）

| ninja 测试文件 | 用例 | moonja 测试文件 |
| --- | --- | --- |
| `lexer_test.cc` | 7 | `lexer_test.mbt` |
| `manifest_parser_test.cc` | 53 | `manifest_parser_test.mbt` |
| `depfile_parser_test.cc` | 29 | `depfile_parser_test.mbt` |
| `graph_test.cc` | 51 | `graph_test.mbt` |
| `build_log_test.cc` | 11 | `build_log_test.mbt` |
| `deps_log_test.cc` | 9 | `deps_log_test.mbt` |
| `dyndep_parser_test.cc` | 42 | `dyndep_parser_test.mbt`（34 个测试块） |
| `build_test.cc` | 118 | `plan_test.mbt` `build_test.mbt` `build_with_log_test.mbt` `deps_build_test.mbt` `dyndep_build_test.mbt` |
| `clean_test.cc` | 19 | `clean_test.mbt` |
| `missing_deps_test.cc` / `json_test.cc` | 7 + 4 | `missing_deps_test.mbt` |
| `edit_distance_test.cc` | 4 | `edit_distance_test.mbt` |
| `clparser_test.cc` / `includes_normalize_test.cc` | 8 + 6 | `clparser_test.mbt`（Windows 用例注入工作目录，在任何平台上都能运行） |
| `elide_middle_test.cc` / `util_test.cc`（StripAnsi） | 3 + 2 | `status_test.mbt` |
| rapidhash | 341 个哈希向量 | `rapidhash_vectors_test.mbt`（向量取自真实 ninja 写出的 `.ninja_log`） |

测试名与原版保持一致（如 `BuildTest.StatusFormatETA`），便于对照。我也做过变异检验：故意改坏实现，确认相应测试会失败。

### 2. 与真实 ninja 做差分测试

`scripts/difftest.mjs` 会把 `tests/diff/` 下的每个用例复制成两份，让 ninja 1.13.2 和 moonja 交替执行同一组步骤（`run`、`touch`、`write`、`rm`），然后比较：

- 每一次运行的 stdout、stderr、退出码；
- 全部步骤结束后的整个文件树内容；
- `.ninja_log` 中每条记录的输出路径和命令哈希。

目前有 13 个用例、142 次运行：基本构建与增量、失败与 `-k`、depfile/deps 日志、restat、清单自重建、phony/order-only/validation、rspfile、dyndep、作用域与转义、25 种错误信息、pool 与 console、`-C`，以及全部子工具在构建前后的输出。在 Windows 上已经全部逐字节一致；CI 已配置为在 Linux 和 Windows 上用 `pip install ninja==1.13.2` 作为参照运行全部用例。

```console
$ moon build --target js
$ node scripts/difftest.mjs --ninja "$(which ninja)"
ok   basic (7 runs)
...
13/13 cases identical, 142 runs compared
```

差分测试找到并修复了不少单元测试没有覆盖到的问题，例如：
- 退出码是原样透传，不是固定的 0/1/2。
- 成功构建后要删除 `.ninja_lock`（ninja 在 `Builder` 析构时清理）。
- `ninja_required_version` 过新时应输出 fatal 而不是 error。
- Windows 上读文件出错时用的是 `FormatMessage` 文本，并且自带 CRLF。
- Windows 版 getopt 会把未知长选项当作短选项解析。

我还验证过框架本身：把 `no work to do.` 改掉一个字符，差分测试会立刻报告。

## 性能

`scripts/bench.mjs` 仿照 ninja 的 `misc/write_fake_manifests.py` 生成工程：1 万个带 gcc deps 的目标文件，分布在 200 个目录中，再链接成库和可执行文件，共 10201 条边，清单 1 MiB。先用 ninja 完整构建一次，再分别计时，每项取 5 次的中位数：

| 场景 | ninja 1.13.2 | moonja（Node 25） | 倍数 |
| --- | ---: | ---: | ---: |
| 只解析清单（`-t targets all`） | 42 ms | 213 ms | 5.0x |
| 全部最新的空构建 | 114 ms | 679 ms | 5.9x |
| 从零开始的空跑（`-n`） | 1207 ms | 2197 ms | 1.8x |

测试环境：Windows 11，i7-10750H。如何解读这些数字：
- Node 启动本身就要约 80 ms。
- 空构建中约 250 ms 花在逐个文件的 `stat` 上。ninja 在 Windows 上用 `FindFirstFileEx` 按目录批量取 mtime，Node 没有对应的接口，单次 stat 约 11 µs。Linux 上 stat 便宜得多，差距会小很多。
- 剖析中发现并修掉了两处热点：rapidhash 在 JS 后端逐字节拼 64 位整数（每个字要做 16 次 BigInt 运算），以及每行输出一次系统调用。

## 架构

```
moonja（核心库，纯 MoonBit，无 I/O）
  lexer / manifest_parser / eval_env    清单语言
  graph / state / scan                  依赖图、脏检查（DependencyScan）
  build                                 Plan + Builder（可恢复的状态机）
  build_log / deps_log / dyndep         持久化格式
  clean / missing_deps / status ...     子工具与输出
moonja/cli（ninja.cc 的主流程，纯 MoonBit）
  flags / ninja / runner / tools        参数、构建循环、子工具；系统能力通过 Host 注入
moonja/cmd（Node.js 宿主）
  fs / child_process / 终端            唯一和操作系统打交道的地方
```

几个关键设计：
- **Builder 是可恢复的状态机**：`start_build` → `command_finished`（每个命令结束时调用一次）。同步宿主可以直接调用 `build`；Node 宿主在 `child_process` 的回调里推进构建，不需要线程。
- **平台是运行时的值**：`Platform::{Posix, Windows}`，不是条件编译。路径规范化（slash_bits）、转义、错误文本都按这个值分支，所以 Windows 行为在任何后端上都能测试。
- **I/O 全部经由 trait 注入**：`Disk`、`FileReader`、`Terminal`、`Processes`。单元测试用内存文件系统 `MemoryDisk` 和假的 Runner；差分测试才使用真实的系统。

## 作为库使用

```moonbit
let state = @moonja.State::new()
let parser = @moonja.ManifestParser::without_files(state)
parser.parse_test("rule cc\n  command = cc $in -o $out\nbuild a.o: cc a.c\n")
for edge in state.edges() {
  println(edge.evaluate_command()) // cc a.c -o a.o
}
```

## 与 ninja 的已知差异

- `-t browse` 和 `-t msvc` 不支持（前者需要 Python，后者是已弃用的 Windows 辅助工具）。
- `-d stats` 可以接受，但不输出统计信息；没有实现 GNU make jobserver 客户端。
- 清单按 UTF-8 解码，非 UTF-8 字节会被替换。
- `-t cleandead -v` 的删除顺序，以及 "did you mean" 在多个候选距离相同时选哪一个：ninja 这两处取决于哈希表的遍历顺序，moonja 按插入顺序。

## 许可证与来源

Apache-2.0。核心算法和测试移植自 [ninja v1.13.2](https://github.com/ninja-build/ninja/tree/v1.13.2)（Apache-2.0）。项目结构参考了 [n2](https://github.com/evmar/n2)。详见 [NOTICE](NOTICE)。
