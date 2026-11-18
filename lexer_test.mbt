// Ported from ninja v1.13.2 src/lexer_test.cc (Apache-2.0, see NOTICE).

///|
test "Lexer.ReadVarValue" {
  let lexer = @moonja.Lexer::new("plain text $var $VaR ${x}\n")
  let eval = lexer.read_var_value()
  assert_eq(eval.serialize(), "[plain text ][$var][ ][$VaR][ ][$x]")
}

///|
test "Lexer.ReadEvalStringEscapes" {
  let lexer = @moonja.Lexer::new("$ $$ab c$: $\ncde\n")
  let eval = lexer.read_var_value()
  assert_eq(eval.serialize(), "[ $ab c: cde]")
}

///|
test "Lexer.ReadIdent" {
  let lexer = @moonja.Lexer::new("foo baR baz_123 foo-bar")
  assert_eq(lexer.read_ident(), Some("foo"))
  assert_eq(lexer.read_ident(), Some("baR"))
  assert_eq(lexer.read_ident(), Some("baz_123"))
  assert_eq(lexer.read_ident(), Some("foo-bar"))
}

///|
test "Lexer.ReadIdentCurlies" {
  // ReadIdent includes dots in the name, but $bar.dots stops at the dot.
  let lexer = @moonja.Lexer::new("foo.dots $bar.dots ${bar.dots}\n")
  assert_eq(lexer.read_ident(), Some("foo.dots"))
  let eval = lexer.read_var_value()
  assert_eq(eval.serialize(), "[$bar][.dots ][$bar.dots]")
}

///|
test "Lexer.Error" {
  let lexer = @moonja.Lexer::new("foo$\nbad $")
  let message = try {
    ignore(lexer.read_var_value())
    ""
  } catch {
    error => error.message()
  }
  assert_eq(
    message,
    (
      #|input:2: bad $-escape (literal $ must be written as $$)
      #|bad $
      #|    ^ near here
    ),
  )
}

///|
test "Lexer.CommentEOF" {
  // A comment without its newline is not a comment.
  let lexer = @moonja.Lexer::new("# foo")
  assert_eq(lexer.read_token(), Error)
}

///|
test "Lexer.Tabs" {
  let lexer = @moonja.Lexer::new("   \tfoobar")
  assert_eq(lexer.read_token(), Indent)
  assert_eq(lexer.read_token(), Error)
  assert_eq(lexer.describe_last_error(), "tabs are not allowed, use spaces")
}
