// Port of ninja v1.13.2 src/metrics.{h,cc} and NinjaMain::DumpMetrics
// (Apache-2.0, see NOTICE): the `-d stats` report.

///|
/// One measured code path (ninja's `Metric`).
priv struct Metric {
  name : String
  mut count : Int32
  /// Nanoseconds spent in it.
  mut sum : Int64
}

///|
priv struct Metrics {
  /// Monotonic nanoseconds.
  clock : () -> Int64
  /// In order of first use, as ninja's static metric pointers register.
  list : Array[Metric]
  by_name : Map[String, Metric]
}

///|
/// ninja's `g_metrics`: set by `-d stats`, before anything is measured.
let g_metrics : Ref[Metrics?] = Ref(None)

///|
/// Starts collecting metrics, timed with `clock` (monotonic nanoseconds).
pub fn enable_metrics(clock : () -> Int64) -> Unit {
  g_metrics.val = Some({ clock, list: [], by_name: Map([]), })
}

///|
/// Stops collecting and forgets what was collected.
pub fn disable_metrics() -> Unit {
  g_metrics.val = None
}

///|
pub fn metrics_enabled() -> Bool {
  g_metrics.val is Some(_)
}

///|
/// A measurement in progress (ninja's `ScopedMetric`). Use it as ninja's
/// `METRIC_RECORD` at the top of a function:
///
/// ```mbt nocheck
/// let metric = @moonja.metric_record("node stat")
/// defer metric.stop()
/// ```
struct ScopedMetric {
  metric : Metric?
  start : Int64
}

///|
/// Starts measuring `name`. With `when=false` nothing is measured, but the
/// metric is still listed, as ninja's `METRIC_RECORD_IF` does.
pub fn metric_record(name : String, when~ : Bool = true) -> ScopedMetric {
  guard g_metrics.val is Some(metrics) else {
    return { metric: None, start: 0, }
  }
  let metric = match metrics.by_name.get(name) {
    Some(metric) => metric
    None => {
      let metric = { name, count: 0, sum: 0, }
      metrics.list.push(metric)
      metrics.by_name[name] = metric
      metric
    }
  }
  if !when {
    return { metric: None, start: 0, }
  }
  { metric: Some(metric), start: (metrics.clock)(), }
}

///|
/// Ends the measurement.
pub fn ScopedMetric::stop(self : ScopedMetric) -> Unit {
  guard self.metric is Some(metric) && g_metrics.val is Some(metrics) else {
    return
  }
  metric.count += 1
  metric.sum += (metrics.clock)() - self.start
}

///|
/// `n / d` printed with `digits` decimals, rounding half to even as
/// printf's `%.Nf` does for exact values.
fn format_ratio(n : Int64, d : Int64, digits : Int32) -> String {
  let mut scale = 1L
  for _ in 0..<digits {
    scale *= 10L
  }
  let scaled = n * scale
  let mut q = scaled / d
  let r = scaled % d
  if r * 2L > d || (r * 2L == d && q % 2L == 1L) {
    q += 1L
  }
  let whole = (q / scale).to_string()
  if digits == 0 {
    return whole
  }
  let frac = (q % scale).to_string()
  whole + "." + "0".repeat(digits - frac.length()) + frac
}

///|
/// `text` padded with spaces on the right to `width` (printf's `%-*s`).
fn pad_right(text : String, width : Int32) -> String {
  if text.length() >= width {
    text
  } else {
    text + " ".repeat(width - text.length())
  }
}

///|
/// The table `-d stats` prints (ninja's `Metrics::Report`), "" when
/// metrics are off.
pub fn metrics_report() -> String {
  guard g_metrics.val is Some(metrics) else { return "" }
  let mut width = 0
  for metric in metrics.list {
    width = @cmp.maximum(width, metric.name.length())
  }
  let out = StringBuilder()
  out.write_string(
    "\{pad_right("metric", width)}\t\{pad_right("count", 6)}\t\{pad_right("avg (us)", 9)}\ttotal (ms)\n",
  )
  for metric in metrics.list {
    let micros = metric.sum / 1000L
    let avg = if metric.count == 0 {
      // ninja divides by zero here; only METRIC_RECORD_IF can get here.
      "-nan"
    } else {
      format_ratio(micros, metric.count.to_int64(), 1)
    }
    out.write_string(
      "\{pad_right(metric.name, width)}\t\{pad_right(metric.count.to_string(), 6)}\t\{pad_right(avg, 8)}\t\{format_ratio(micros, 1000L, 1)}\n",
    )
  }
  out.to_string()
}

///|
/// The number of buckets ninja's `std::unordered_map` of paths has after
/// `entries` insertions. Windows ninja is built with the MSVC STL: 8
/// buckets, then whenever an insertion would push the load factor over
/// 1.0, 8 times as many while under 512, else the next power of two.
/// Elsewhere it is libstdc++ (libc++ on macOS), whose prime bucket counts
/// moonja does not model: None.
pub fn path_map_buckets(entries : Int32, platform~ : Platform) -> Int32? {
  guard platform is Windows else { return None }
  let mut buckets = 8
  for size in 1..<=entries {
    // MSVC compares float(size) / float(buckets) with the float load factor.
    if Float::from_int(size) / Float::from_int(buckets) > 1.0 {
      buckets = if buckets < 512 && buckets * 8 >= size {
        buckets * 8
      } else {
        let mut pow = 1
        while pow < size {
          pow *= 2
        }
        pow
      }
    }
  }
  Some(buckets)
}

///|
/// What `-d stats` prints after a build (ninja's `NinjaMain::DumpMetrics`).
/// Where moonja does not know the bucket count it prints `?`.
pub fn State::dump_metrics(self : State) -> String {
  let count = self.paths.length()
  let hash_line = match path_map_buckets(count, platform=self.platform) {
    Some(buckets) =>
      "path->node hash load \{format_ratio(count.to_int64(), buckets.to_int64(), 2)} (\{count} entries / \{buckets} buckets)\n"
    None => "path->node hash load ? (\{count} entries / ? buckets)\n"
  }
  metrics_report() + "\n" + hash_line
}
