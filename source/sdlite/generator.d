/** Functionality for converting DOM nodes to SDLang documents.
*/
module sdlite.generator;

import sdlite.ast;

import core.time;
import std.datetime;
import std.range;
import taggedalgebraic.taggedunion : visit;


/** Writes out a range of `SDLNode`s to a `char` based output range.
*/
void generateSDLang(R, NR)(ref R dst, NR nodes, size_t level = 0)
	if (isOutputRange!(R, char) && isInputRange!NR && is(ElementType!NR : const(SDLNode)))
{
	foreach (ref n; nodes)
		generateSDLang(dst, n, level);
}

unittest {
	auto app = appender!string;
	app.generateSDLang([
		SDLNode("na"),
		SDLNode("nb", [SDLValue.int_(1), SDLValue.int_(2)]),
		SDLNode("nc", [SDLValue.int_(1)], [SDLAttribute("a", SDLValue.int_(2))]),
		SDLNode("nd", null, [SDLAttribute("a", SDLValue.int_(1)), SDLAttribute("b", SDLValue.int_(2))]),
		SDLNode("ne", null, null, [
			SDLNode("foo:nf", null, null, [
				SDLNode("ng")
			]),
		])
	]);
	assert(app.data ==
`na
nb 1 2
nc 1 a=2
nd a=1 b=2
ne {
	foo:nf {
		ng
	}
}
`, app.data);
}


/** Writes out single `SDLNode` to a `char` based output range.
*/
void generateSDLang(R)(ref R dst, in auto ref SDLNode node, size_t level = 0)
{
	auto name = node.qualifiedName == "content" ? "" : node.qualifiedName;
	dst.putIndentation(level);
	dst.put(name);
	foreach (ref v; node.values) {
		dst.put(' ');
		dst.generateSDLang(v);
	}
	foreach (ref a; node.attributes) {
		dst.put(' ');
		dst.put(a.qualifiedName);
		dst.put('=');
		dst.generateSDLang(a.value);
	}
	if (node.children) {
		dst.put(" {\n");
		dst.generateSDLang(node.children, level + 1);
		dst.putIndentation(level);
		dst.put("}\n");
	} else dst.put('\n');
}


/** Writes a single SDLang value to the given output range.
*/
void generateSDLang(R)(ref R dst, in auto ref SDLValue value)
{
	import std.format : formattedWrite;

	// NOTE: using final switch instead of visit, because the latter causes
	//       the creation of a heap delegate

	final switch (value.kind) {
		case SDLValue.Kind.null_:
			dst.put("null");
			break;
		case SDLValue.Kind.text:
			dst.put('"');
			dst.escapeSDLString(value.textValue);
			dst.put('"');
			break;
		case SDLValue.Kind.binary:
			dst.put('[');
			dst.generateBase64(value.binaryValue);
			dst.put(']');
			break;
		case SDLValue.Kind.int_:
			dst.formattedWrite("%s", value.intValue);
			break;
		case SDLValue.Kind.long_:
			dst.formattedWrite("%sL", value.longValue);
			break;
		case SDLValue.Kind.decimal:
			assert(false);
		case SDLValue.Kind.float_:
			dst.writeFloat(value.floatValue);
			dst.put('f');
			break;
		case SDLValue.Kind.double_:
			dst.writeFloat(value.doubleValue);
			break;
		case SDLValue.Kind.bool_:
			dst.put(value.boolValue ? "true" : "false");
			break;
		case SDLValue.Kind.dateTime:
			auto dt = cast(DateTime)value.dateTimeValue;
			auto fracsec = value.dateTimeValue.fracSecs;
			dst.formattedWrite("%d/%02d/%02d %02d:%02d:%02d",
				dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
			dst.writeFracSecs(fracsec.total!"hnsecs");

			auto tz = value.dateTimeValue.timezone;

			if (tz is LocalTime()) {}
			else if (tz is UTC()) dst.put("-UTC");
			else if (auto sz = cast(immutable(SimpleTimeZone))tz) {
				long hours, minutes;
				sz.utcOffset.split!("hours", "minutes")(hours, minutes);
				if (hours < 0 || minutes < 0)
					dst.formattedWrite("-GMT-%02d:%02d", -hours, -minutes); // NOTE: should really be UTC, but we are following the spec here
				else dst.formattedWrite("-GMT+%02d:%02d", hours, minutes);
			} else {
				auto offset = tz.utcOffsetAt(value.dateTimeValue.stdTime);
				long hours, minutes;
				offset.split!("hours", "minutes")(hours, minutes);
				if (hours < 0 || minutes < 0)
					dst.formattedWrite("-GMT-%02d:%02d", -hours, -minutes); // NOTE: should really be UTC, but we are following the spec here
				else dst.formattedWrite("-GMT+%02d:%02d", hours, minutes);
				//dst.formattedWrite("-%s", tz.stdName); // Q: should this be name instead (e.g. CEST vs. CET)
			}
			break;
		case SDLValue.Kind.date:
			auto d = value.dateValue;
			dst.formattedWrite("%d/%02d/%02d", d.year, d.month, d.day);
			break;
		case SDLValue.Kind.duration:
			long days, hours, minutes, seconds, hnsecs;
			value.durationValue.split!("days", "hours", "minutes", "seconds", "hnsecs")
				(days, hours, minutes, seconds, hnsecs);
			if (days > 0) dst.formattedWrite("%sd:", days);
			dst.formattedWrite("%02d:%02d", hours, minutes);
			if (seconds != 0 || hnsecs != 0) {
				dst.formattedWrite(":%02d", seconds);
				dst.writeFracSecs(hnsecs);
			}
			break;
	}
}

unittest {
	import std.array : appender;

	void test(SDLValue v, string exp)
	{
		auto app = appender!string;
		app.generateSDLang(v);
		assert(app.data == exp, app.data);
	}

	test(SDLValue.null_, "null");
	test(SDLValue.bool_(false), "false");
	test(SDLValue.bool_(true), "true");
	test(SDLValue.text("foo\"bar"), `"foo\"bar"`);
	test(SDLValue.binary(cast(immutable(ubyte)[])"hello, world!"), "[aGVsbG8sIHdvcmxkIQ==]");
	test(SDLValue.int_(int.max), "2147483647");
	test(SDLValue.int_(int.min), "-2147483648");
	test(SDLValue.long_(long.max), "9223372036854775807L");
	test(SDLValue.long_(long.min), "-9223372036854775808L");
	test(SDLValue.float_(2.2f), "2.2f");
	test(SDLValue.double_(2.2), "2.2");
	test(SDLValue.double_(1.0), "1.0"); // make sure there is always a fractional part
	test(SDLValue.date(Date(2015, 12, 6)), "2015/12/06");
	test(SDLValue.duration(12.hours + 14.minutes + 34.seconds), "12:14:34");
	test(SDLValue.duration(12.hours + 14.minutes + 34.seconds + 123.msecs), "12:14:34.123");
	test(SDLValue.duration(2.days + 12.hours + 14.minutes + 34.seconds), "2d:12:14:34");
	test(SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0))), "2015/12/06 12:00:00");
	test(SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), 123.msecs)), "2015/12/06 12:00:00.123");
	test(SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), UTC())), "2015/12/06 12:00:00-UTC");
	test(SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), new immutable SimpleTimeZone(-2.hours - 30.minutes))), "2015/12/06 12:00:00-GMT-02:30");
	test(SDLValue.dateTime(SysTime(DateTime(2015, 12, 6, 12, 0, 0), new immutable SimpleTimeZone(31.minutes))), "2015/12/06 12:00:00-GMT+00:31");
	test(SDLValue.dateTime(SysTime(DateTime(2017, 11, 22, 18, 0, 0), new immutable SimpleTimeZone(0.hours))), "2017/11/22 18:00:00-GMT+00:00");
}


/** Escapes a given string to ensure safe usage within an SDLang quoted string.
*/
void escapeSDLString(R)(ref R dst, in char[] str)
{
	// TODO: insert line breaks
	foreach (char ch; str) {
		switch (ch) {
			default: dst.put(ch); break;
			case '"': dst.put(`\"`); break;
			case '\\': dst.put(`\\`); break;
			case '\t': dst.put(`\t`); break;
			case '\n': dst.put(`\n`); break;
			case '\r': dst.put(`\r`); break;
		}
	}
}

unittest {
	import std.array : appender;

	auto app = appender!string;
	app.escapeSDLString("foo\\bar\r\n\t\tbäz\"");
	assert(app.data == `foo\\bar\r\n\t\tbäz\"`, app.data);
}

private void putIndentation(R)(ref R dst, size_t level)
{
	foreach (i; 0 .. level)
		dst.put('\t');
}

// output a floating point number in pure decimal format, without losing
// precision (at least approximately) and without redundant zeros
private void writeFloat(R, F)(ref R dst, const(F) num)
{
	import std.format : formattedWrite;
	import std.math : floor, fmod, isNaN, log10;

	static if (is(F == float)) enum sig = 7;
	else enum sig = 15;

	if (num.isNaN || num == F.infinity || num == -F.infinity) {
		dst.put("0.0");
		return;
	}

	if (!num) {
		dst.put("0.0");
		return;
	}

	if (fmod(num, F(1)) == 0) dst.formattedWrite("%.1f", num);
	else {
		F unum;
		if (num < 0) {
			dst.put('-');
			unum = -num;
		} else unum = num;

		auto firstdig = cast(long)floor(log10(unum));
		if (firstdig >= sig) dst.formattedWrite("%.1f", unum);
		else {
			char[32] fmt;
			char[] fmtdst = fmt[];
			fmtdst.formattedWrite("%%.%sg", sig - firstdig);
			dst.formattedWrite(fmt[0 .. $-fmtdst.length], unum);
		}
	}
}

unittest {
	void test(F)(F v, string txt)
	{
		auto app = appender!string;
		app.writeFloat(v);
		assert(app.data == txt, app.data);
	}

	test(float.infinity, "0.0");
	test(-float.infinity, "0.0");
	test(float.nan, "0.0");

	test(double.infinity, "0.0");
	test(-double.infinity, "0.0");
	test(double.nan, "0.0");

	test(0.0, "0.0");
	test(1.0, "1.0");
	test(-1.0, "-1.0");
	test(0.0f, "0.0");
	test(1.0f, "1.0");
	test(-1.0f, "-1.0");

	test(100.0, "100.0");
	test(0.0078125, "0.0078125");
	test(100.001, "100.001");
	test(-100.0, "-100.0");
	test(-0.0078125, "-0.0078125");
	test(-100.001, "-100.001");
	test(100.0f, "100.0");
	test(0.0078125f, "0.0078125");
	test(100.01f, "100.01");
	test(-100.0f, "-100.0");
	test(-0.0078125f, "-0.0078125");
	test(-100.01f, "-100.01");
}

private void writeFracSecs(R)(ref R dst, long hnsecs)
{
	import std.format : formattedWrite;

	assert(hnsecs >= 0 && hnsecs < 10_000_000);

	if (hnsecs > 0) {
		if (hnsecs % 10_000 == 0)
			dst.formattedWrite(".%03d", hnsecs / 10_000);
		else dst.formattedWrite(".%07d", hnsecs);
	}
}

unittest {
	import std.array : appender;

	void test(Duration dur, string exp)
	{
		auto app = appender!string;
		app.writeFracSecs(dur.total!"hnsecs");
		assert(app.data == exp, app.data);
	}

	test(0.msecs, "");
	test(123.msecs, ".123");
	test(123400.usecs, ".1234000");
	test(1234567.hnsecs, ".1234567");
}


private void generateBase64(R)(ref R dst, in ubyte[] bytes)
{
	import std.base64 : Base64;

	Base64.encode(bytes, dst);
}
