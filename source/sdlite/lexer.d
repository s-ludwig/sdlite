module sdlite.lexer;

import sdlite.ast : SDLValue;
import sdlite.internal : MultiAppender;

import std.algorithm.comparison : among;
import std.algorithm.mutation : move, swap;
import std.range;
import std.datetime : Date, DateTime, LocalTime, PosixTimeZone, SimpleTimeZone,
	SysTime, TimeZone, UTC, WindowsTimeZone;
import std.uni : isAlpha, isWhite;
import std.utf : byCodeUnit, decodeFront;
import core.time : Duration, days, hours, minutes, seconds, msecs, hnsecs;


struct Token(R) {
	alias SourceRange = R;

	TokenType type;
	Location location;
	Take!R whitespacePrefix;
	Take!R text;
}

enum TokenType {
	invalid,
	eof,
	eol,
	assign,
	namespace,
	blockOpen,
	blockClose,
	semicolon,
	comment,
	identifier,
	null_,
	text,
	binary,
	number,
	boolean,
	dateTime,
	date,
	duration
}

struct Location {
	/// Name of the source file
	string file;
	/// Line within the file (Unix/Windows/Mac line endings are recognized)
	size_t line;
	/// Byte offset from the start of the line
	size_t column;
	/// Byte offset from the start of the input string
	size_t offset;
}


/** Returns a range of `SDLToken`s by lexing the given SDLang input.
*/
auto lexSDLang(const(char)[] input, string filename = "")
{
	return lexSDLang(input.byCodeUnit, filename);
}
/// ditto
auto lexSDLang(R)(R input, string filename = "")
	if (isForwardRange!R && is(immutable(ElementType!R) == immutable(char)))
{
	return SDLangLexer!R(input, filename);
}


package SDLValue parseValue(R)(ref Token!R t,
	ref MultiAppender!(immutable(char)) char_appender,
	ref MultiAppender!(immutable(ubyte)) byte_appender)
{
	import std.algorithm.comparison : min, max;
	import std.algorithm.iteration : splitter;
	import std.algorithm.searching : endsWith, findSplit;
	import std.conv : parse, to;
	import std.exception : assumeUnique;
	import std.format : formattedRead;
	import std.typecons : Rebindable;
	import std.uni : icmp;

	final switch (t.type) {
		case TokenType.invalid:
		case TokenType.eof:
		case TokenType.eol:
		case TokenType.assign:
		case TokenType.namespace:
		case TokenType.blockOpen:
		case TokenType.blockClose:
		case TokenType.semicolon:
		case TokenType.comment:
		case TokenType.identifier:
			 return SDLValue.null_;
		case TokenType.null_:
			 return SDLValue.null_;
		case TokenType.text:
			assert(!t.text.empty);
			if (t.text.front == '`') {
				auto txt = t.text
					.save
					.dropOne
					.take(t.text.length - 2);
				foreach (ch; txt) char_appender.put(ch);
				return SDLValue.text(char_appender.extractArray);
			} else {
				assert(t.text.front == '"');
				t.parseTextValue(char_appender);
				return SDLValue.text(char_appender.extractArray);
			}
		case TokenType.binary:
			t.parseBinaryValue(byte_appender);
			return SDLValue.binary(byte_appender.extractArray);
		case TokenType.number:
			auto numparts = t.text.save.findSplit(".");
			if (numparts[1].empty) { // integer or integer-like float
				auto num = parse!long(numparts[0]);
				if (numparts[0].empty)
					return SDLValue.int_(cast(int)num.min(int.max).max(int.min));

				switch (numparts[0].front) {
					default: assert(false);
					case 'l', 'L': return SDLValue.long_(num);
					case 'd', 'D': return SDLValue.double_(num);
					case 'f', 'F': return SDLValue.float_(num);
				}
			}

			auto r = t.text.save;

			if (numparts[2].length >= 2) {
				if (numparts[2].save.tail(2).icmp("bd") == 0)
					return SDLValue.null_; // decimal not yet supported
				if (numparts[2].save.retro.front.among!('f', 'F'))
					return SDLValue.float_(r.parse!float);
			}
			return SDLValue.double_(r.parse!double);
		case TokenType.boolean:
			switch (t.text.front) {
				default: assert(false);
				case 't': return SDLValue.bool_(true);
				case 'f': return SDLValue.bool_(false);
				case 'o':
					auto txt = t.text.save.dropOne;
					return SDLValue.bool_(txt.front == 'n');
			}
		case TokenType.date:
			int y, m, d;
			t.text.save.formattedRead("%d/%d/%d", y, m, d);
			return SDLValue.date(Date(y, m, d));
		case TokenType.duration:
			auto parts = t.text.save.splitter(":");
			int d, h, m, s;
			if (parts.front.save.endsWith("d")) {
				d = parts.front.dropBackOne.to!int();
				parts.popFront();
			}
			h = parts.front.to!int();
			parts.popFront();
			m = parts.front.to!int();
			parts.popFront();
			auto sec = parts.front.findSplit(".");
			s = sec[0].to!int;
			Duration fracsec = Duration.zero;
			if (!sec[1].empty) {
				auto l0 = sec[2].length;
				long fs = sec[2].parse!long();
				fracsec = (fs * (10 ^^ (7 - l0))).hnsecs;
			}
			return SDLValue.duration(d.days + h.hours + m.minutes + s.seconds + fracsec);
		case TokenType.dateTime:
			int y, m, d, hh, mm, ss;
			auto txt = t.text.save;
			txt.formattedRead("%d/%d/%d %d:%d", y, m, d, hh, mm);
			if (!txt.empty && txt.front == ':') {
				txt.popFront();
				ss = txt.parse!int();
			}
			auto dt = DateTime(y, m, d, hh, mm, ss);
			Rebindable!(immutable(TimeZone)) tz;
			Duration fracsec = Duration.zero;

			if (!txt.empty && txt.front == '.') {
				txt.popFront();
				auto l0 = txt.length;
				long fs = txt.parse!long();
				fracsec = (fs * (10 ^^ (7 - l0))).hnsecs;
			}

			if (!txt.empty) {
				txt.popFront();
				char[3] tzt;
				txt.formattedRead("%c%c%c", tzt[0], tzt[1], tzt[2]);
				if (!txt.empty) {
					int mul = txt.front == '-' ? -1 : 1;
					txt.popFront();
					int dh = txt.parse!int();
					int dm = 0;
					if (!txt.empty) {
						txt.formattedRead(":%d", dm);
					}
					tz = new immutable SimpleTimeZone((mul*dh).hours + (mul*dm).minutes);
				} else if (tzt == "UTC" || tzt == "GMT") {
					tz = UTC();
				} else {
					version (Windows) tz = WindowsTimeZone.getTimeZone(tzt[].idup);
					else tz = PosixTimeZone.getTimeZone(tzt[].idup);
				}
			} else tz = LocalTime();

			return SDLValue.dateTime(SysTime(dt, fracsec, tz));
	}
}

package void parseTextValue(R, DR)(ref Token!R t, ref DR dst)
{
	import std.algorithm.mutation : copy;

	assert(t.type == TokenType.text);
	assert(!t.text.empty);

	auto content = t.text.save.dropOne().take(t.text.length - 2);

	if (t.text.front == '`') { // WYSIWYG string
		foreach (char ch; content)
			dst.put(ch);
		return;
	}

	assert(t.text.front == '"');

	static void skipWhitespace(R)(ref R r)
	{
		while (!r.empty && r.front.among!(' ', '\t'))
			r.popFront();
	}

	while (content.length) {
		char ch = content.front;
		content.popFront();

		if (ch != '\\') dst.put(ch);
		else {
			assert(!content.empty);
			ch = content.front;
			content.popFront();

			switch (ch) {
				default: assert(false);
				case '\r':
					if (!content.empty && content.front == '\n')
						content.popFront();
					skipWhitespace(content);
					break;
				case '\n': skipWhitespace(content); break;
				case 'r': dst.put('\r'); break;
				case 'n': dst.put('\n'); break;
				case 't': dst.put('\t'); break;
				case '"': dst.put('"'); break;
				case '\\': dst.put('\\'); break;
			}
		}
	}
}

package void parseBinaryValue(R, DR)(ref Token!R t, ref DR dst)
{
	import std.base64 : Base64;

	assert(!t.text.empty);
	assert(t.text.front == '[');

	auto content = t.text.save.dropOne.take(t.text.length - 2);
	char[4] buf;

	while (!content.empty) {
		foreach (i; 0 .. 4) {
			while (content.front.among!(' ', '\t', '\r', '\n'))
				content.popFront();
			buf[i] = content.front;
			content.popFront();
		}

		ubyte[3] bytes;
		dst.put(Base64.decode(buf[], bytes[]));
	}
}

private struct SDLangLexer(R)
	if (isForwardRange!R && is(immutable(ElementType!R) == immutable(char)))
{
	private {
		R m_input;
		Location m_location;
		Token!R m_token;
		bool m_empty;
	}

	/** Initializes a lexer for the given input SDL document.

		The document must be given in the form of a UTF-8 encoded text that is
		stored as a `ubyte` forward range.
	*/
	this(R input, string filename)
	{
		m_input = input.move;
		m_location.file = filename;

		readNextToken();
	}

	@property bool empty() const { return m_empty; }

	ref inout(Token!R) front()
	inout {
		return m_token;
	}

	SDLangLexer save()
	{
		SDLangLexer ret;
		ret.m_input = m_input.save;
		ret.m_location = m_location;
		ret.m_token = m_token;
		ret.m_empty = m_empty;
		return ret;
	}

	void popFront()
	{
		assert(!empty);
		if (m_token.type == TokenType.eof) m_empty = true;
		else readNextToken();
	}

	private void readNextToken()
	{
		m_token.whitespacePrefix = skipWhitespace();
		m_token.location = m_location;

		if (m_input.empty) {
			m_token.type = TokenType.eof;
			m_token.text = m_input.take(0);
			return;
		}

		auto tstart = m_input.save;
		m_token.type = skipToken();
		m_token.text = tstart.take(m_location.offset - m_token.location.offset);
	}

	private TokenType skipToken()
	{
		bool in_identifier;

		switch (m_input.front) {
			case '\r':
				skipChar!true();
				if (!m_input.empty && m_input.front == '\n')
					skipChar!false();
				return TokenType.eol;
			case '\n':
				skipChar!true();
				return TokenType.eol;
			case '/': // C/C++ style comment
				skipChar!false();
				if (m_input.empty || !m_input.front.among!('/', '*')) {
					return TokenType.invalid;
				}
				if (m_input.front == '/') {
					skipChar!false();
					skipLine();

					return TokenType.comment;
				}

				skipChar!false();

				while (true) {
					while (!m_input.empty && m_input.front != '*')
						skipChar!true();

					if (!m_input.empty) skipChar!false();

					if (m_input.empty) {
						return TokenType.invalid;
					}

					if (m_input.front == '/') {
						skipChar!false();
						return TokenType.comment;
					}
				}
				assert(false);
			case '-': // LUA style comment or negative number
				skipChar!false();

				if (m_input.empty) return TokenType.invalid;

				auto ch = m_input.front;
				if (ch >= '0' && ch <= '9')
					return skipNumericToken();

				if (ch != '-') return TokenType.invalid;

				skipChar!false();
				skipLine();

				return TokenType.comment;
			case '#': // shell style comment
				skipChar!false();
				skipLine();
				return TokenType.comment;
			case '"': // normal string
				skipChar!false();

				outerstr: while (!m_input.empty) {
					char ch = m_input.front;
					if (ch.among!('\r', '\n')) break;

					skipChar!false();

					if (ch == '"') {
						return TokenType.text;
					} else if (ch == '\\') {
						ch = m_input.front;
						skipChar!false();
						switch (ch) {
							default: break outerstr;
							case '"', '\\', 'n', 'r', 't': break;
							case '\n', '\r':
								skipChar!true();
								skipWhitespace();
								break;
						}
					}
				}

				return TokenType.invalid;
			case '`': // WYSIWYG string
				skipChar!false();

				while (!m_input.empty) {
					if (m_input.front == '`') {
						skipChar!false();
						return TokenType.text;
					}

					skipChar!true();
				}

				return TokenType.invalid;
			case '[': // base64 data
				import std.array : appender;

				skipChar!false();


				uint chunklen = 0;

				while (!m_input.empty) {
					auto ch = m_input.front;
					switch (ch) {
						case ']':
							skipChar!false();
							if (chunklen != 0) { // content length must be a multiple of 4
								return TokenType.invalid;
							}
							return TokenType.binary;
						case '0': .. case '9':
						case 'A': .. case 'Z':
						case 'a': .. case 'z':
						case '+', '/', '=':
							if (++chunklen == 4)
								chunklen = 0;
							skipChar!false();
							break;
						case ' ', '\t': skipChar!false(); break;
						case '\r', '\n': skipChar!true(); break;
						default: return TokenType.invalid;
					}

				}

				return TokenType.invalid;
			case '{': skipChar!false(); return TokenType.blockOpen;
			case '}': skipChar!false(); return TokenType.blockClose;
			case ';': skipChar!false(); return TokenType.semicolon;
			case '=': skipChar!false(); return TokenType.assign;
			case ':': skipChar!false(); return TokenType.namespace;
			case '0': .. case '9': // number or date/time
				return skipNumericToken();
			case 't':
				skipChar!false();
				if (skipOver("rue")) {
					return TokenType.boolean;
				}
				in_identifier = true;
				goto default;
			case 'f':
				skipChar!false();
				if (skipOver("alse")) {
					return TokenType.boolean;
				}
				in_identifier = true;
				goto default;
			case 'o':
				skipChar!false();
				in_identifier = true;
				if (m_input.empty) goto default;
				if (m_input.front == 'n') {
					skipChar!false();
					return TokenType.boolean;
				}
				if (m_input.front == 'f') {
					skipChar!false();
					if (!m_input.empty && m_input.front == 'f') {
						skipChar!false();
						return TokenType.boolean;
					}
				}
				goto default;
			case 'n':
				skipChar!false();
				if (skipOver("ull")) {
					return TokenType.null_;
				}
				in_identifier = true;
				goto default;
			case '_':
				in_identifier = true;
				goto default;
			default: // identifier
				if (!in_identifier) {
					auto ch = m_input.front;
					switch (ch) {
						case '0': .. case '9':
						case 'A': .. case 'Z':
						case 'a': .. case 'z':
						case '_':
							skipChar!false();
							break;
						default:
							size_t n;
							auto dch = m_input.decodeFront(n);
							m_location.offset += n;
							m_location.column += n;
							if (!dch.isAlpha && dch != '_')
								return TokenType.invalid;
							break;
					}
				}

				outer: while (!m_input.empty) {
					char ch = m_input.front;
					switch (ch) {
						case '0': .. case '9':
						case 'A': .. case 'Z':
						case 'a': .. case 'z':
						case '_', '-', '.', '$':
							skipChar!false();
							break;
						default:
							// all eglible ASCII characters are handled above
							if (!(ch & 0x80)) break outer;

							// test if this is a Unicode alphabectical character
							auto inp = m_input.save;
							size_t n;
							dchar dch = m_input.decodeFront(n);
							if (!isAlpha(dch)) {
								swap(inp, m_input);
								break outer;
							}
							m_location.offset += n;
							m_location.column += n;
							break;

					}
				}

				return TokenType.identifier;
		}
	}

	private TokenType skipNumericToken()
	{
		assert(m_input.front >= '0' && m_input.front <= '9');
		skipChar!false();

		while (!m_input.empty && m_input.front >= '0' && m_input.front <= '9')
			skipChar!false();

		if (m_input.empty) // unqualified integer
			return TokenType.number;

		auto ch = m_input.front;
		switch (ch) { // unqualified integer
			default:
				return TokenType.number;
			case ':': // time span
				if (!skipDuration(No.includeFirstNumber)) {
					return TokenType.invalid;
				}
				return TokenType.duration;
			case 'D': // double with no fractional part
				skipChar!false();
				return TokenType.number;
			case 'f', 'F': // float with no fractional part
				skipChar!false();
				return TokenType.number;
			case 'd': // time span with days or double value
				skipChar!false();
				if (m_input.empty || m_input.front != ':') {
					return TokenType.number;
				}

				skipChar!false();

				if (!skipDuration(Yes.includeFirstNumber)) {
					return TokenType.invalid;
				}
				return TokenType.duration;
			case '/': // date
				if (!skipDate(No.includeFirstNumber)) {
					return TokenType.invalid;
				}
				if (m_input.empty || m_input.front != ' ') {
					return TokenType.date;
				}

				auto input_saved = m_input.save;
				auto loc_saved = m_location;

				skipChar!false();

				if (!skipTimeOfDay()) {
					swap(m_input, input_saved);
					swap(m_location, loc_saved);
					return TokenType.date;
				}

				if (!m_input.empty && m_input.front == '-') {
					skipChar!false();
					if (!skipTimeZone()) {
						return TokenType.invalid;
					}
				}

				return TokenType.dateTime;
			case '.': // floating point
				skipChar!false();
				if (m_input.front < '0' || m_input.front > '9') {
					return TokenType.invalid;
				}

				while (!m_input.empty && m_input.front >= '0' && m_input.front <= '9')
					skipChar!false();

				if (m_input.empty || m_input.front.among!('f', 'F', 'd', 'D')) { // IEEE floating-point
					if (!m_input.empty) skipChar!false();
					return TokenType.number;
				}

				if (m_input.front.among!('b', 'B')) { // decimal
					skipChar!false();
					if (!m_input.front.among!('d', 'D')) { // FIXME: only "bd" or "BD" should be allowed, not "bD"
						return TokenType.invalid;
					}

					skipChar!false();
					return TokenType.number;
				}

				// TODO: decimal
				return TokenType.invalid;
			case 'l', 'L': // long integer
				skipChar!false();
				return TokenType.number;
		}
	}

	private Take!R skipWhitespace()
	{
		size_t n = 0;
		auto ret = m_input.save;
		while (!m_input.empty && m_input.front.among!(' ', '\t')) {
			skipChar!false();
			n++;
		}
		return ret.take(n);
	}

	private bool skipOver(string s)
	{
		while (!m_input.empty && s.length > 0) {
			if (m_input.front != s[0]) return false;
			s = s[1 .. $];
			m_location.offset++;
			m_location.column++;
			m_input.popFront();
		}
		return s.length == 0;
	}

	private void skipLine()
	{
		while (!m_input.empty && !m_input.front.among!('\r', '\n'))
			skipChar!false();
		if (!m_input.empty) skipChar!true();
	}

	private void skipChar(bool could_be_eol)()
	{
		static if (could_be_eol) {
			auto c = m_input.front;
			m_input.popFront();
			m_location.offset++;
			if (c == '\r') {
				m_location.line++;
				m_location.column = 0;
				if (!m_input.empty && m_input.front == '\n') {
					m_input.popFront();
					m_location.offset++;
				}
			} else if (c == '\n') {
				m_location.line++;
				m_location.column = 0;
			} else m_location.column++;
		} else {
			m_input.popFront();
			m_location.offset++;
			m_location.column++;
		}
	}

	private bool skipDate(Flag!"includeFirstNumber" include_first_number)
	{
		if (include_first_number)
			if (!skipInteger()) return false;
		if (!skipOver("/")) return false;
		if (!skipInteger()) return false;
		if (!skipOver("/")) return false;
		if (!skipInteger()) return false;
		return true;
	}

	private bool skipDuration(Flag!"includeFirstNumber" include_first_number)
	{
		if (include_first_number)
			if (!skipInteger()) return false;
		if (!skipOver(":")) return false;
		if (!skipInteger()) return false;
		if (!skipOver(":")) return false;
		if (!skipInteger()) return false;
		if (!m_input.empty && m_input.front == '.') {
			skipChar!false();
			if (!skipInteger()) return false;
		}
		return true;
	}

	private bool skipTimeOfDay()
	{
		if (!skipInteger()) return false;
		if (!skipOver(":")) return false;
		if (!skipInteger()) return false;
		if (!m_input.empty && m_input.front != ':') return true;
		skipChar!false();
		if (!skipInteger()) return false;
		if (!m_input.empty && m_input.front == '.') {
			skipChar!false();
			if (!skipInteger()) return false;
		}
		return true;
	}

	private bool skipTimeZone()
	{
		foreach (i; 0 .. 3) {
			auto ch = m_input.front;
			if (ch < 'A' && ch > 'Z') return false;
			skipChar!false();
		}

		if (m_input.empty || !m_input.front.among!('-', '+'))
			return true;
		skipChar!false();

		if (!skipInteger()) return false;

		if (m_input.empty || m_input.front != ':')
			return true;
		skipChar!false();

		if (!skipInteger()) return false;

		return true;
	}

	private bool skipInteger()
	{
		if (m_input.empty) return false;

		char ch = m_input.front;
		if (ch < '0' || ch > '9') return false;
		skipChar!false();

		while (!m_input.empty) {
			ch = m_input.front;
			if (ch < '0' || ch > '9') break;
			skipChar!false();
		}

		return true;
	}
}

unittest { // single token tests
	MultiAppender!(immutable(char)) chapp;
	MultiAppender!(immutable(ubyte)) btapp;

	void test(string sdl, TokenType tp, string txt, SDLValue val = SDLValue.null_, string ws = "", bool multiple = false)
	{
		auto t = SDLangLexer!(typeof(sdl.byCodeUnit))(sdl.byCodeUnit, "test");
		assert(!t.empty);
		assert(t.front.type == tp);
		assert(t.front.whitespacePrefix.source == ws);
		assert(t.front.text.source == txt);
		assert(t.front.parseValue(chapp, btapp) == val);
		t.popFront();
		assert(multiple || t.front.type == TokenType.eof);
	}

	test("\n", TokenType.eol, "\n");
	test("\r", TokenType.eol, "\r");
	test("\r\n", TokenType.eol, "\r\n");
	test("=", TokenType.assign, "=");
	test(":", TokenType.namespace, ":");
	test("{", TokenType.blockOpen, "{");
	test("}", TokenType.blockClose, "}");
	test("// foo", TokenType.comment, "// foo");
	test("# foo", TokenType.comment, "# foo");
	test("-- foo", TokenType.comment, "-- foo");
	test("-- foo\n", TokenType.comment, "-- foo\n");
	test("foo", TokenType.identifier, "foo");
	test("foo ", TokenType.identifier, "foo");
	test("foo$.-_ ", TokenType.identifier, "foo$.-_");
	test("föö", TokenType.identifier, "föö");
	test("null", TokenType.null_, "null", SDLValue.null_);
	test("true", TokenType.boolean, "true", SDLValue.bool_(true));
	test("false", TokenType.boolean, "false", SDLValue.bool_(false));
	test("on", TokenType.boolean, "on", SDLValue.bool_(true));
	test("off", TokenType.boolean, "off", SDLValue.bool_(false));
	/*test("on_", TokenType.identifier, "on_");
	test("off_", TokenType.identifier, "of_");
	test("true_", TokenType.identifier, "true_");
	test("false_", TokenType.identifier, "false_");
	test("null_", TokenType.identifier, "null_");*/
	test("-", TokenType.invalid, "-");
	test("%", TokenType.invalid, "%");
	test("\\", TokenType.invalid, "\\");
	//test("\\\n", TokenType.eof, "\\\n");
	test("`foo`", TokenType.text, "`foo`", SDLValue.text("foo"));
	test("`fo\\\"o`", TokenType.text, "`fo\\\"o`", SDLValue.text("fo\\\"o"));
	test(`"foo"`, TokenType.text, `"foo"`, SDLValue.text("foo"));
	test(`"f\"oo"`, TokenType.text, `"f\"oo"`, SDLValue.text("f\"oo"));
	test("\"f \\\n   oo\"", TokenType.text, "\"f \\\n   oo\"", SDLValue.text("f oo"));
	test("[aGVsbG8sIHdvcmxkIQ==]", TokenType.binary, "[aGVsbG8sIHdvcmxkIQ==]", SDLValue.binary(cast(immutable(ubyte)[])"hello, world!"));
	test("[aGVsbG8sI \t \n \t HdvcmxkIQ==]", TokenType.binary, "[aGVsbG8sI \t \n \t HdvcmxkIQ==]", SDLValue.binary(cast(immutable(ubyte)[])"hello, world!"));
	test("[aGVsbG8sIHdvcmxkIQ]", TokenType.invalid, "[aGVsbG8sIHdvcmxkIQ]");
	test("[aGVsbG8sIHdvcmxk$Q==]", TokenType.invalid, "[aGVsbG8sIHdvcmxk", SDLValue.null_, "", true);
	test("5", TokenType.number, "5", SDLValue.int_(5));
	test("123", TokenType.number, "123", SDLValue.int_(123));
	test("-123", TokenType.number, "-123", SDLValue.int_(-123));
	test("123l", TokenType.number, "123l", SDLValue.long_(123));
	test("123L", TokenType.number, "123L", SDLValue.long_(123));
	test("123.123", TokenType.number, "123.123", SDLValue.double_(123.123));
	test("123.123f", TokenType.number, "123.123f", SDLValue.float_(123.123));
	test("123.123F", TokenType.number, "123.123F", SDLValue.float_(123.123));
	test("123.123d", TokenType.number, "123.123d", SDLValue.double_(123.123));
	test("123.123D", TokenType.number, "123.123D", SDLValue.double_(123.123));
	test("123d", TokenType.number, "123d", SDLValue.double_(123));
	test("123D", TokenType.number, "123D", SDLValue.double_(123));
	test("123.123bd", TokenType.number, "123.123bd"); // TODO
	test("123.123BD", TokenType.number, "123.123BD"); // TODO
	test("2015/12/06", TokenType.date, "2015/12/06", SDLValue.date(Date(2015, 12, 6)));
	test("12:14:34", TokenType.duration, "12:14:34", SDLValue.duration(12.hours + 14.minutes + 34.seconds));
	test("12:14:34.123", TokenType.duration, "12:14:34.123", SDLValue.duration(12.hours + 14.minutes + 34.seconds + 123.msecs));
	test("2d:12:14:34", TokenType.duration, "2d:12:14:34", SDLValue.duration(2.days + 12.hours + 14.minutes + 34.seconds));
	test("2015/12/06 12:00:00.000", TokenType.dateTime, "2015/12/06 12:00:00.000", SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0))));
	test("2015/12/06 12:00:00.000-UTC", TokenType.dateTime, "2015/12/06 12:00:00.000-UTC", SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), UTC())));
	test("2015/12/06 12:00:00-GMT-2:30", TokenType.dateTime, "2015/12/06 12:00:00-GMT-2:30", SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), new immutable SimpleTimeZone(-2.hours - 30.minutes))));
	test("2015/12/06 12:00:00-GMT+0:31", TokenType.dateTime, "2015/12/06 12:00:00-GMT+0:31", SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), new immutable SimpleTimeZone(31.minutes))));
	test("2015/12/06 ", TokenType.date, "2015/12/06", SDLValue.date(Date(2015, 12, 6)));
	test("2017/11/22 18:00-GMT+00:00", TokenType.dateTime, "2017/11/22 18:00-GMT+00:00", SDLValue.dateTime(SysTime(DateTime(2017, 11, 22, 18, 0, 0), new immutable SimpleTimeZone(0.hours))));

	test(" {", TokenType.blockOpen, "{", SDLValue.null_, " ");
	test("\t {", TokenType.blockOpen, "{", SDLValue.null_, "\t ");
}
