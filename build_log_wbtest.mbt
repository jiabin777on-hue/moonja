///|
test "erase_entries moves the last entry into each hole, as emhash8 does" {
  let log = BuildLog::new()
  for output in ["d1", "g1", "d2", "d3", "g2", "d4", "d5", "g3", "d6", "kept"] {
    log.entries[output] = {
      output,
      command_hash: 0,
      start_time: 0,
      end_time: 0,
      mtime: 0,
    }
  }
  log.erase_entries(["g1", "g2", "g3", "missing"])
  let order = StringBuilder()
  for output, _ in log.entries {
    order.write_string(output + " ")
  }
  inspect(order.to_string(), content="d1 kept d2 d3 d6 d4 d5 ")
}
