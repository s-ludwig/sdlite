module sdlite.parser;

import sdlite.ast;
import sdlite.internal : MultiAppender;
import sdlite.lexer;

void parseSDLDocument(alias NodeHandler, R)(R input, string filename)
{
	import std.algorithm.comparison : among;
	import std.algorithm.iteration : filter;

	auto tokens = lexSDLang(input, filename)
		.filter!(t => t.type != TokenType.comment);

	ParserContext ctx;

	parseNodes!NodeHandler(tokens, ctx, 0);

	while (!tokens.empty) {
		if (!tokens.front.type.among(TokenType.eof, TokenType.comment))
			throw new SDLParserException(tokens.front, "Expected end of file");
		tokens.popFront();
	}
}

unittest {
	void test(string sdl, SDLNode[] expected)
	{
		SDLNode[] result;
		parseSDLDocument!((n) { result ~= n; })(sdl, "test");
		import std.conv : to;
		assert(result == expected, result.to!string);
	}

	test("foo", [SDLNode("foo")]);
	test("foo:bar", [SDLNode("foo:bar")]);
	test("foo 123", [SDLNode("foo",
		[SDLValue.int_(123)])]);
	test("foo null\nbar", [SDLNode("foo", [SDLValue.null_]), SDLNode("bar")]);
	test("foo null;bar", [SDLNode("foo", [SDLValue.null_]), SDLNode("bar")]);
	test("foo {\n}\n\nbar", [SDLNode("foo"), SDLNode("bar")]);
	test("foo bar=123", [SDLNode("foo", null,
		[SDLAttribute("bar", SDLValue.int_(123))])]);
	test("foo 42 bar=123", [SDLNode("foo",
		[SDLValue.int_(42)],
		[SDLAttribute("bar", SDLValue.int_(123))])]);
	test("foo {\nbar\n}", [SDLNode("foo", null, null, [SDLNode("bar")])]);
	test("foo {\nbar\n}\nbaz", [SDLNode("foo", null, null, [SDLNode("bar")]), SDLNode("baz")]);
	test("\nfoo", [SDLNode("foo")]);
}

final class SDLParserException : Exception {
	private {
		Location m_location;
		string m_error;
	}

	nothrow:

	this(R)(ref Token!R token, string error, string file = __FILE__, int line = __LINE__, Throwable next_in_chain = null)
	{
		this(token.location, error, file, line, next_in_chain);
	}

	this(Location location, string error, string file = __FILE__, int line = __LINE__, Throwable next_in_chain = null)
	{
		import std.exception : assumeWontThrow;
		import std.format : format;

		string msg = format("%s:%s: %s", location.file, location.line+1, error).assumeWontThrow;

		super(msg, file, line, next_in_chain);

		m_location = location;
		m_error = error;
	}

	@property string error() const { return m_error; }
	@property Location location() const { return m_location; }
}

private void parseNodes(alias NodeHandler, R)(ref R tokens, ref ParserContext ctx, size_t depth)
{
	import std.algorithm.comparison : among;

	while (!tokens.empty && tokens.front.type.among(TokenType.eol, TokenType.semicolon))
		tokens.popFront();

	while (!tokens.empty && !tokens.front.type.among(TokenType.eof, TokenType.blockClose)) {
		bool nested;
		auto n = tokens.parseNode(ctx, depth, nested);
		NodeHandler(n);

		if (!nested && !tokens.empty && !tokens.front.type.among(TokenType.eol, TokenType.semicolon, TokenType.eof))
			throwUnexpectedToken(tokens.front, "end of node");

		while (!tokens.empty && tokens.front.type.among(TokenType.eol, TokenType.semicolon))
			tokens.popFront();
	}
}

private SDLNode parseNode(R)(ref R tokens, ref ParserContext ctx, size_t depth, out bool is_nested)
{
	SDLNode ret;

	bool require_parameters = false;

	ret.location = tokens.front.location;
	auto n = tokens.parseQualifiedName(false, ctx);
	if (n is null) {
		n = "content";
		require_parameters = true;
	}

	ret.qualifiedName = n;
	ret.values = tokens.parseValues(ctx);
	import std.conv;
	if (require_parameters && ret.values.length == 0)
		throwUnexpectedToken(tokens.front, "values for anonymous node");
	ret.attributes = tokens.parseAttributes(ctx);

	if (!tokens.empty && tokens.front.type == TokenType.blockOpen) {
		is_nested = true;
		tokens.popFront();
		tokens.skipToken(TokenType.eol);

		if (ctx.nodeAppender.length <= depth)
			ctx.nodeAppender.length = depth+1;
		tokens.parseNodes!((ref n) { ctx.nodeAppender[depth].put(n); })(ctx, depth+1);
		ret.children = ctx.nodeAppender[depth].extractArray;

		if (tokens.empty || tokens.front.type != TokenType.blockClose)
			throwUnexpectedToken(tokens.front, "'}'");

		tokens.popFront();
		if (!tokens.empty && tokens.front.type != TokenType.eof)
			tokens.skipToken(TokenType.eol);
	}

	return ret;
}

private SDLAttribute[] parseAttributes(R)(ref R tokens, ref ParserContext ctx)
{
	while (!tokens.empty && tokens.front.type == TokenType.identifier) {
		SDLAttribute att;
		att.qualifiedName = tokens.parseQualifiedName(true, ctx);
		tokens.skipToken(TokenType.assign);
		if (!tokens.parseValue(att.value, ctx))
			throwUnexpectedToken(tokens.front, "attribute value");
		ctx.attributeAppender.put(att);
	}

	return ctx.attributeAppender.extractArray;
}

private SDLValue[] parseValues(R)(ref R tokens, ref ParserContext ctx)
{
	while (!tokens.empty) {
		SDLValue v;
		if (!tokens.parseValue(v, ctx))
			break;
		ctx.valueAppender.put(v);
	}

	return ctx.valueAppender.extractArray;
}

private bool parseValue(R)(ref R tokens, ref SDLValue dst, ref ParserContext ctx)
{
	switch (tokens.front.type) {
		default: return false;
		case TokenType.null_:
		case TokenType.text:
		case TokenType.binary:
		case TokenType.number:
		case TokenType.boolean:
		case TokenType.dateTime:
		case TokenType.date:
		case TokenType.duration:
			dst = sdlite.lexer.parseValue!(typeof(tokens.front).SourceRange)(tokens.front, ctx.charAppender, ctx.bytesAppender);
			tokens.popFront();
			return true;
	}
}

private string parseQualifiedName(R)(ref R tokens, bool required, ref ParserContext ctx)
{
	import std.array : array;
	import std.exception : assumeUnique;
	import std.range : chain;
	import std.utf : byCodeUnit;

	if (tokens.front.type != TokenType.identifier) {
		if (required) throwUnexpectedToken(tokens.front, "identifier");
		else return null;
	}

	foreach (ch; tokens.front.text)
		ctx.charAppender.put(ch);
	tokens.popFront();

	if (!tokens.empty && tokens.front.type == TokenType.namespace) {
		tokens.popFront();
		if (tokens.empty || tokens.front.type != TokenType.identifier)
			throwUnexpectedToken(tokens.front, "identifier");

		ctx.charAppender.put(':');
		foreach (ch; tokens.front.text)
			ctx.charAppender.put(ch);
		tokens.popFront();
	}

	return ctx.charAppender.extractArray;
}

private void skipToken(R)(ref R tokens, scope TokenType[] allowed_types...)
{
	import std.algorithm.iteration : map;
	import std.algorithm.searching : canFind;
	import std.format : format;

	if (tokens.empty) throw new SDLParserException(tokens.front, "Unexpected end of file");
	if (!allowed_types.canFind(tokens.front.type)) {
		string msg = allowed_types.length == 1
			? format("Unexpected %s, expected %s",
				stringRepresentation(tokens.front),
				stringRepresentation(allowed_types[0]))
			: format("Unexpected %s, expected any of %(%s/%)",
				stringRepresentation(tokens.front),
				allowed_types.map!(t => stringRepresentation(t)));
		throw new SDLParserException(tokens.front, msg);
	}

	tokens.popFront();
}

private void throwUnexpectedToken(R)(ref Token!R t, string expected)
{
	throw new SDLParserException(t, "Unexpected " ~ stringRepresentation(t) ~ ", expected " ~ expected);
}

private string stringRepresentation(R)(ref Token!R t)
@safe {
	import std.conv : to;

	switch (t.type) with (TokenType) {
		case invalid: return "malformed token '" ~ t.text.to!string ~ "'";
		case identifier: return "identifier '"~t.text.to!string~"'";
		default: return stringRepresentation(t.type);
	}
}

private string stringRepresentation(TokenType tp)
@safe {
	import std.conv : to;

	final switch (tp) with (TokenType) {
		case invalid: return "malformed token";
		case eof: return "end of file";
		case eol: return "end of line";
		case assign: return "'='";
		case namespace: return "':'";
		case blockOpen: return "'{'";
		case blockClose: return "'}'";
		case semicolon: return "';'";
		case comment: return "comment";
		case identifier: return "identifier";
		case null_: return "'null'";
		case text: return "string";
		case binary: return "binary data";
		case number: return "number";
		case boolean: return "Boolean value";
		case dateTime: return "date/time value";
		case date: return "date value";
		case duration: return "duration value";
	}
}

private struct ParserContext {
	MultiAppender!SDLValue valueAppender;
	MultiAppender!SDLAttribute attributeAppender;
	MultiAppender!(immutable(char)) charAppender;
	MultiAppender!(immutable(ubyte)) bytesAppender;
	MultiAppender!SDLNode[] nodeAppender; // one for each recursion depth
}


unittest {
	void test(string code, string error, int line = 1)
	{
		import std.format : format;
		auto msg = format("foo.sdl:%s: %s", line, error);
		try {
			parseSDLDocument!((n) {})(code, "foo.sdl");
			assert(false, "Expected parsing to fail");
		}
		catch (SDLParserException ex) assert(ex.msg == msg, ">"~ex.msg~"< >"~msg~"<");
		catch (Exception e) assert(false, "Unexpected exception type");
	}

	test("foo=bar", "Unexpected '=', expected end of node");
	test("foo bar=15/34/x", "Unexpected malformed token '15/34/', expected attribute value");
	test("foo bar=baz", "Unexpected identifier 'baz', expected attribute value");
	test("foo \"bar\" \\ \"bar\"", "Unexpected malformed token '\\', expected end of node");
	test("foo:", "Unexpected end of file, expected identifier");
	test("foo:\n", "Unexpected end of line, expected identifier");
	test(":", "Unexpected ':', expected values for anonymous node");
	test("{\n}", "Unexpected '{', expected values for anonymous node");
	test(" foo {\n}:", "Unexpected ':', expected end of line", 2);
	test(" foo {\n}\n:", "Unexpected ':', expected values for anonymous node", 3);
}
