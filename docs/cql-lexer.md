# The CQL lexer (2026-11-08)

One lenient scanner for pando-CQL text, `KorporaEngine/Sources/KorporaEngine/CQLLexer.swift`, read by everything that needs to know
what a quote, a regex, a bracket or a region tag is. Before it, six backwards checks in `CQLCompletion.swift` and four regexes in
`CQLQueryField` each had their own idea (the open-quote check knew nothing of `/regex/`; keywords were coloured inside quoted values;
`<` after a tag was never paired), and `QueryNodes` would have been a seventh.

**What it is:** tokens with UTF-16 ranges and the bracket depth around them: strings and regexes (flagged when the text ends inside
them), identifiers (dotted: `doc.author`, `a.lemma`), numbers, brackets, comparisons (`=`, `!=`, `<=`, `>=`, and `<` `>` inside a
token), dependency arrows (`> < >> << !> !<`), negation, `&` `|`, the colon after a node's name, `::`, `=:`, `;`, region tags (`<s>`,
`</text>`, `<text genre="Book">`, flagged when still open), and repeat marks (`*` `+` `?` `{1,2}` right after a token).
It never fails and never needs the query to be complete. It does not say whether the query is valid: pando decides that.

**The one judgement call: `<`.** Between tokens it is an arrow after an operand (`[] <`, `[] <b:[]`) and opens a region tag
elsewhere (`<s>`, after a closed tag, after a scoping word such as `within <s>`); `</` is always a closing tag. The auto-pairing uses the
same rule, so `<s> <` and `within <` now pair to `<>` and `[] <` does not.

**Who uses it**
- `QueryNodes` (the nodes of a query, for frequencies and collocations).
- `CQLCompletionContext.at` (what the caret is in), which gained: `a.` after `::` offers that token's attributes (`a.lemma`);
  nothing is offered inside a regex; `!` is followed by attribute names; `<` and `<te` offer region names; `<text gen` offers that
  region's attributes (not inside a value); conditions after `::` offer the names the user gave to tokens, then pando's functions.
- `CQLAutoPairing` (is the caret after an operand?).
- The colouring (`CQLQueryField.colorRuns`): values red, scoping words and relations before a `[` purple, operators and arrows
  orange, region tags teal. A word inside a quoted value is a value, not a keyword (it was coloured purple before).

**Not done:** error underlines (pando reports a position for a syntax error, but there is no way to ask for one without running the
query); completing attribute *values*.

Tests: `CQLLexerTests` (engine, 23), `CQLLexerCompletionTests` (app, 17), and the existing completion, pairing and `QueryNodes` tests,
which pass unchanged except where the new behaviour is the point (names offered after `::`; the keyword colouring test now reads
tokens, not a pattern).
