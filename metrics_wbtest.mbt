///|
test "format_ratio rounds half to even like printf" {
  inspect(format_ratio(5, 8, 2), content="0.62")
  inspect(format_ratio(7, 8, 2), content="0.88")
  inspect(format_ratio(1, 8, 2), content="0.12")
  inspect(format_ratio(3, 8, 2), content="0.38")
  inspect(format_ratio(1234, 1000, 1), content="1.2")
  inspect(format_ratio(1250, 1000, 1), content="1.2")
  inspect(format_ratio(1350, 1000, 1), content="1.4")
  inspect(format_ratio(7, 1, 1), content="7.0")
  inspect(format_ratio(0, 3, 2), content="0.00")
  inspect(format_ratio(2, 3, 1), content="0.7")
}

///|
test "path_map_buckets follows emhash8's growth policy" {
  let buckets = StringBuilder()
  for n in [0, 1, 3, 4, 6, 7, 11, 12, 13, 100, 1000, 200000] {
    buckets.write_string("\{n}:\{path_map_buckets(n)} ")
  }
  // 11 entries in 16 buckets is what ninja 1.13.2 printed in CI.
  inspect(
    buckets.to_string(),
    content="0:4 1:4 3:4 4:8 6:8 7:16 11:16 12:16 13:32 100:128 1000:2048 200000:262144 ",
  )
}

///|
test "metrics_report lists metrics in order of first use" {
  let now = Ref(0L)
  enable_metrics(fn() { now.val })
  defer disable_metrics()
  let tick = fn(name : String, micros : Int64, when : Bool) {
    let metric = metric_record(name, when~)
    now.val += micros * 1000L
    metric.stop()
  }
  tick("node stat", 3, true)
  tick(".ninja parse", 1500, true)
  tick("node stat", 4, true)
  // METRIC_RECORD_IF lists the metric but does not count it.
  tick(".ninja parse", 99, false)
  inspect(
    metrics_report(),
    content=(
      #|metric      	count 	avg (us) 	total (ms)
      #|node stat   	2     	3.5     	0.0
      #|.ninja parse	1     	1500.0  	1.5
      #|
    ),
  )
}

///|
test "dump_metrics adds the path map load" {
  enable_metrics(fn() { 0L })
  defer disable_metrics()
  let state = State::new()
  for name in ["a", "b", "c", "d", "e"] {
    ignore(state.get_node(name, 0))
  }
  inspect(
    state.dump_metrics(),
    content=(
      #|metric	count 	avg (us) 	total (ms)
      #|
      #|path->node hash load 0.62 (5 entries / 8 buckets)
      #|
    ),
  )
  inspect(
    State::new().dump_metrics(),
    content=(
      #|metric	count 	avg (us) 	total (ms)
      #|
      #|path->node hash load 0.00 (0 entries / 4 buckets)
      #|
    ),
  )
}

///|
test "no metrics without -d stats" {
  disable_metrics()
  let metric = metric_record("node stat")
  metric.stop()
  inspect(metrics_enabled(), content="false")
  inspect(metrics_report(), content="")
}
