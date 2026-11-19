// Ported from ninja v1.13.2 src/clean_test.cc (Apache-2.0, see NOTICE).

///|
/// CleanTest: a state with the `cat` rule, a memory disk and a quiet
/// config.
struct CleanFixture {
  state : @moonja.State
  fs : @moonja.MemoryDisk
  config : @moonja.BuildConfig
}

///|
fn clean_fixture(
  input : String,
  files~ : Array[String] = [],
) -> CleanFixture raise {
  let fs = @moonja.MemoryDisk::new()
  for f in files {
    fs.create(f, "")
  }
  { state: state_with_cat(input), fs, config: quiet_config(), }
}

///|
fn CleanFixture::cleaner(self : CleanFixture) -> @moonja.Cleaner {
  @moonja.Cleaner::new(self.state, self.config, self.fs, reader=self.fs)
}

///|
fn CleanFixture::mtime(self : CleanFixture, path : String) -> Int64 raise {
  @moonja.Disk::stat(self.fs, path)
}

///|
let four_cats : String = "build in1: cat src1\nbuild out1: cat in1\nbuild in2: cat src2\nbuild out2: cat in2\n"

///|
let four_files : Array[String] = ["in1", "out1", "in2", "out2"]

///|
test "CleanTest.CleanAll" {
  let f = clean_fixture(four_cats, files=four_files)
  let cleaner = f.cleaner()
  assert_eq(cleaner.cleaned_files_count(), 0)
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 4)
  assert_eq(f.fs.files_removed().length(), 4)
  for path in four_files {
    assert_eq(f.mtime(path), 0)
  }
  f.fs.files_removed().clear()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed().length(), 0)
}

///|
test "CleanTest.CleanAllDryRun" {
  let f = clean_fixture(four_cats, files=four_files)
  f.config.dry_run = true
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 4)
  assert_eq(f.fs.files_removed().length(), 0)
  for path in four_files {
    assert_true(f.mtime(path) > 0)
  }
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 4)
  assert_eq(f.fs.files_removed().length(), 0)
}

///|
test "CleanTest.CleanTarget" {
  let f = clean_fixture(four_cats, files=four_files)
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_target("out1"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
  assert_eq(f.mtime("in1"), 0)
  assert_eq(f.mtime("out1"), 0)
  assert_true(f.mtime("in2") > 0)
  assert_true(f.mtime("out2") > 0)
  f.fs.files_removed().clear()
  assert_eq(cleaner.clean_target("out1"), 0)
  assert_eq(cleaner.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed().length(), 0)
}

///|
test "CleanTest.CleanTargetDryRun" {
  let f = clean_fixture(four_cats, files=four_files)
  f.config.dry_run = true
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_target("out1"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 0)
  for path in four_files {
    assert_true(f.mtime(path) > 0)
  }
  assert_eq(cleaner.clean_target("out1"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 0)
}

///|
let cat_e_manifest : String = "rule cat_e\n  command = cat -e $in > $out\nbuild in1: cat_e src1\nbuild out1: cat in1\nbuild in2: cat_e src2\nbuild out2: cat in2\n"

///|
test "CleanTest.CleanRule" {
  let f = clean_fixture(cat_e_manifest, files=four_files)
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_rule("cat_e"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
  assert_eq(f.mtime("in1"), 0)
  assert_true(f.mtime("out1") > 0)
  assert_eq(f.mtime("in2"), 0)
  assert_true(f.mtime("out2") > 0)
  f.fs.files_removed().clear()
  assert_eq(cleaner.clean_rule("cat_e"), 0)
  assert_eq(cleaner.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed().length(), 0)
}

///|
test "CleanTest.CleanRuleDryRun" {
  let f = clean_fixture(cat_e_manifest, files=four_files)
  f.config.dry_run = true
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_rule("cat_e"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 0)
  for path in four_files {
    assert_true(f.mtime(path) > 0)
  }
  assert_eq(cleaner.clean_rule("cat_e"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 0)
}

///|
test "CleanTest.CleanRuleGenerator" {
  let f = clean_fixture(
    "rule regen\n  command = cat $in > $out\n  generator = 1\nbuild out1: cat in1\nbuild out2: regen in2\n",
    files=["out1", "out2"],
  )
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 1)
  assert_eq(f.fs.files_removed().length(), 1)
  f.fs.create("out1", "")
  assert_eq(cleaner.clean_all(generator=true), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
}

///|
let clean_cc_depfile : String = "rule cc\n  command = cc $in > $out\n  depfile = $out.d\nbuild out1: cc in1\n"

///|
test "CleanTest.CleanDepFile" {
  let f = clean_fixture(clean_cc_depfile, files=["out1", "out1.d"])
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
}

///|
test "CleanTest.CleanDepFileOnCleanTarget" {
  let f = clean_fixture(clean_cc_depfile, files=["out1", "out1.d"])
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_target("out1"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
}

///|
test "CleanTest.CleanDepFileOnCleanRule" {
  let f = clean_fixture(clean_cc_depfile, files=["out1", "out1.d"])
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_rule("cc"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
}

///|
test "CleanTest.CleanDyndep" {
  // A dyndep file can name another output to clean.
  let f = clean_fixture("build out: cat in || dd\n  dyndep = dd\n", files=[
    "in", "out", "out.imp",
  ])
  f.fs.create("dd", "ninja_dyndep_version = 1\nbuild out | out.imp: dyndep\n")
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
  assert_eq(f.mtime("out"), 0)
  assert_eq(f.mtime("out.imp"), 0)
}

///|
test "CleanTest.CleanDyndepMissing" {
  // A missing dyndep file is tolerated.
  let f = clean_fixture("build out: cat in || dd\n  dyndep = dd\n", files=[
    "in", "out", "out.imp",
  ])
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 1)
  assert_eq(f.fs.files_removed().length(), 1)
  assert_eq(f.mtime("out"), 0)
  assert_eq(f.mtime("out.imp"), 1)
}

///|
test "CleanTest.CleanRspFile" {
  let f = clean_fixture(
    "rule cc\n  command = cc $in > $out\n  rspfile = $rspfile\n  rspfile_content=$in\nbuild out1: cc in1\n  rspfile = cc1.rsp\n",
    files=["out1", "cc1.rsp"],
  )
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 2)
}

///|
test "CleanTest.CleanRsp" {
  let f = clean_fixture(
    "rule cat_rsp \n  command = cat $rspfile > $out\n  rspfile = $rspfile\n  rspfile_content = $in\nbuild in1: cat src1\nbuild out1: cat in1\nbuild in2: cat_rsp src2\n  rspfile=in2.rsp\nbuild out2: cat_rsp in2\n  rspfile=out2.rsp\n",
    files=["in1", "out1", "in2.rsp", "out2.rsp", "in2", "out2"],
  )
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_target("out1"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(cleaner.clean_target("in2"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(cleaner.clean_rule("cat_rsp"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_eq(f.fs.files_removed().length(), 6)
  for path in ["in1", "out1", "in2", "out2", "in2.rsp", "out2.rsp"] {
    assert_eq(f.mtime(path), 0)
  }
}

///|
test "CleanTest.CleanFailure" {
  let f = clean_fixture("build dir: cat src1\n")
  ignore(@moonja.Disk::make_dir(f.fs, "dir"))
  assert_true(f.cleaner().clean_all() != 0)
}

///|
test "CleanTest.CleanPhony" {
  let f = clean_fixture(
    "build phony: phony t1 t2\nbuild t1: cat\nbuild t2: cat\n",
    files=["phony", "t1", "t2"],
  )
  // clean_all does not remove "phony".
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_true(f.mtime("phony") > 0)
  f.fs.create("t1", "")
  f.fs.create("t2", "")
  // Nor does clean_target.
  assert_eq(cleaner.clean_target("phony"), 0)
  assert_eq(cleaner.cleaned_files_count(), 2)
  assert_true(f.mtime("phony") > 0)
}

///|
test "CleanTest.CleanDepFileAndRspFileWithSpaces" {
  let f = clean_fixture(
    "rule cc_dep\n  command = cc $in > $out\n  depfile = $out.d\nrule cc_rsp\n  command = cc $in > $out\n  rspfile = $out.rsp\n  rspfile_content = $in\nbuild out$ 1: cc_dep in$ 1\nbuild out$ 2: cc_rsp in$ 1\n",
    files=["out 1", "out 2", "out 1.d", "out 2.rsp"],
  )
  let cleaner = f.cleaner()
  assert_eq(cleaner.clean_all(), 0)
  assert_eq(cleaner.cleaned_files_count(), 4)
  assert_eq(f.fs.files_removed().length(), 4)
  for path in ["out 1", "out 2", "out 1.d", "out 2.rsp"] {
    assert_eq(f.mtime(path), 0)
  }
}

///|
/// CleanDeadTest: a build log written from `old_manifest`, then cleaned
/// with the fixture's manifest.
fn clean_dead_log(
  f : CleanFixture,
  old_state : @moonja.State,
) -> @moonja.BuildLog raise {
  let path = "CleanTest-tempfile"
  let log1 = @moonja.BuildLog::new()
  log1.open_for_write(f.fs, path, fn(_) { false })
  log1.record_command(f.fs, old_state.edges()[0], 15, 18)
  log1.record_command(f.fs, old_state.edges()[1], 20, 25)
  log1.close(f.fs)
  let log2 = @moonja.BuildLog::new()
  let (status, error) = log2.load(f.fs, path)
  assert_true(status is Success)
  assert_eq(error, "")
  assert_eq(log2.entries().length(), 2)
  assert_true(log2.lookup_by_output("out1") is Some(_))
  assert_true(log2.lookup_by_output("out2") is Some(_))
  // The log file itself does not count as removed or present below.
  ignore(@moonja.Disk::remove_file(f.fs, path))
  f.fs.files_removed().clear()
  log2
}

///|
fn old_cat_state() -> @moonja.State raise {
  let state = @moonja.State::new()
  @moonja.ManifestParser::without_files(state).parse_test(
    "rule cat\n  command = cat $in > $out\nbuild out1: cat in\nbuild out2: cat in\n",
  )
  state
}

///|
test "CleanDeadTest.CleanDead" {
  let old_state = old_cat_state()
  let f = clean_fixture("build out2: cat in\n", files=["in", "out1", "out2"])
  let log = clean_dead_log(f, old_state)
  // The manifest that still builds out1.
  let cleaner1 = @moonja.Cleaner::new(old_state, f.config, f.fs)
  assert_eq(cleaner1.clean_dead(log.entries()), 0)
  assert_eq(cleaner1.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed().length(), 0)
  for path in ["in", "out1", "out2"] {
    assert_true(f.mtime(path) != 0)
  }
  // The manifest that does not build out1 anymore.
  let cleaner2 = f.cleaner()
  assert_eq(cleaner2.clean_dead(log.entries()), 0)
  assert_eq(cleaner2.cleaned_files_count(), 1)
  assert_eq(f.fs.files_removed(), ["out1"])
  assert_true(f.mtime("in") != 0)
  assert_eq(f.mtime("out1"), 0)
  assert_true(f.mtime("out2") != 0)
  // Nothing to do now.
  assert_eq(cleaner2.clean_dead(log.entries()), 0)
  assert_eq(cleaner2.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed(), ["out1"])
}

///|
test "CleanDeadTest.CleanDeadPreservesInputs" {
  let old_state = old_cat_state()
  // out1 is no longer built, but is an implicit input: keep it.
  let f = clean_fixture("build out2: cat in | out1\n", files=[
    "in", "out1", "out2",
  ])
  let log = clean_dead_log(f, old_state)
  let cleaner1 = @moonja.Cleaner::new(old_state, f.config, f.fs)
  assert_eq(cleaner1.clean_dead(log.entries()), 0)
  assert_eq(cleaner1.cleaned_files_count(), 0)
  let cleaner2 = f.cleaner()
  assert_eq(cleaner2.clean_dead(log.entries()), 0)
  assert_eq(cleaner2.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed().length(), 0)
  for path in ["in", "out1", "out2"] {
    assert_true(f.mtime(path) != 0)
  }
  assert_eq(cleaner2.clean_dead(log.entries()), 0)
  assert_eq(cleaner2.cleaned_files_count(), 0)
  assert_eq(f.fs.files_removed().length(), 0)
}
