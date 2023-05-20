module sdlite.parser;

import sdlite.ast;
import sdlite.internal : MultiAppender;
import sdlite.lexer;

void parseSDLDocument(alias NodeHandler, R)(R input, string filename)
{
	import std.algorithm.comparison : among;
	import std.algorithm.iteration : filter;

	auto tokens = lexSDLang(input, filename)
		.filter!(t => t.type != TokenType.comment)
		.backslashSkipper;

	ParserContext ctx;

	parseNodes!NodeHandler(tokens, ctx, 0);

	while (!tokens.empty) {
		if (!tokens.front.type.among(TokenType.eof, TokenType.comment))
			throw new Exception("Expected end of file");
		tokens.popFront();
	}
}

private auto backslashSkipper(T)(auto ref scope return T range)
{
	static struct Ret
	{
		T range;

		ref auto front() @property
		{
			return range.front;
		}
		
		bool empty() @property
		{
			return range.empty;
		}
		
		void popFront()
		{
			range.popFront();
			if (!range.empty && range.front.type == TokenType.backslash)
			{
				range.popFront();
				if (!range.empty && range.front.type == TokenType.eol)
					range.popFront();
				else
					throw new Exception("Expected EOL after backslash");
			}
		}
		
		typeof(this) save()
		{
			return this;
		}
	}

	return Ret(range);
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
	test("foo \\\nnull\nbar", [SDLNode("foo", [SDLValue.null_]), SDLNode("bar")]);
	test("foo null;bar", [SDLNode("foo", [SDLValue.null_]), SDLNode("bar")]);
	test("foo {\n}\n\nbar", [SDLNode("foo"), SDLNode("bar")]);
	test("foo bar=123", [SDLNode("foo", null,
		[SDLAttribute("bar", SDLValue.int_(123))])]);
	test("foo\\\n\t42\\\n\tbar=123", [SDLNode("foo",
		[SDLValue.int_(42)],
		[SDLAttribute("bar", SDLValue.int_(123))])]);
	test("foo {\nbar\n}", [SDLNode("foo", null, null, [SDLNode("bar")])]);
	test("\nfoo", [SDLNode("foo")]);
}

private void parseNodes(alias NodeHandler, R)(ref R tokens, ref ParserContext ctx, size_t depth)
{
	import std.algorithm.comparison : among;

	while (!tokens.empty && tokens.front.type.among(TokenType.eol, TokenType.semicolon))
		tokens.popFront();

	while (!tokens.empty && !tokens.front.type.among(TokenType.eof, TokenType.blockClose)) {
		auto n = tokens.parseNode(ctx, depth);
		NodeHandler(n);

		while (!tokens.empty && tokens.front.type.among(TokenType.eol, TokenType.semicolon))
			tokens.popFront();
	}
}

private SDLNode parseNode(R)(ref R tokens, ref ParserContext ctx, size_t depth)
{
	SDLNode ret;

	bool require_parameters = false;

	auto n = tokens.parseQualifiedName(false, ctx);
	if (n is null) {
		n = "content";
		require_parameters = true;
	}

	ret.qualifiedName = n;
	ret.values = tokens.parseValues(ctx);
	import std.conv;
	if (require_parameters && ret.values.length == 0)
		throw new Exception("Expected values for anonymous node"~tokens.front.to!string);
	ret.attributes = tokens.parseAttributes(ctx);

	if (!tokens.empty && tokens.front.type == TokenType.blockOpen) {
		tokens.popFront();
		tokens.skipToken(TokenType.eol);

		if (ctx.nodeAppender.length <= depth)
			ctx.nodeAppender.length = depth+1;
		tokens.parseNodes!((ref n) { ctx.nodeAppender[depth].put(n); })(ctx, depth+1);
		ret.children = ctx.nodeAppender[depth].extractArray;

		if (tokens.empty || tokens.front.type != TokenType.blockClose)
			throw new Exception("Expected }");

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
			throw new Exception("Expected attribute value");
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
		if (required) throw new Exception("Expected identifier");
		else return null;
	}

	foreach (ch; tokens.front.text)
		ctx.charAppender.put(ch);
	tokens.popFront();

	if (!tokens.empty && tokens.front.type == TokenType.namespace) {
		tokens.popFront();
		if (tokens.empty || tokens.front.type != TokenType.identifier)
			throw new Exception("Expected identifier");

		ctx.charAppender.put(':');
		foreach (ch; tokens.front.text)
			ctx.charAppender.put(ch);
		tokens.popFront();
	}

	return ctx.charAppender.extractArray;
}

private void skipToken(R)(ref R tokens, scope TokenType[] allowed_types...)
{
	import std.algorithm.searching : canFind;
	import std.format : format;

	if (tokens.empty) throw new Exception("Unexpected end of file");
	if (!allowed_types.canFind(tokens.front.type))
		throw new Exception(format("Unexpected token at line %s, %s, expected any of %s", tokens.front.location.line+1, tokens.front.type, allowed_types));

	tokens.popFront();
}

private struct ParserContext {
	MultiAppender!SDLValue valueAppender;
	MultiAppender!SDLAttribute attributeAppender;
	MultiAppender!(immutable(char)) charAppender;
	MultiAppender!(immutable(ubyte)) bytesAppender;
	MultiAppender!SDLNode[] nodeAppender; // one for each recursion depth
}
