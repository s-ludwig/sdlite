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
void generateSDLang(R)(ref R dst, in ref SDLNode node, size_t level = 0)
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


private void generateSDLang(R)(ref R dst, in ref SDLValue value)
{
	import std.format : formattedWrite;

	value.visit!(
		() { dst.put("null"); },
		(string v) { dst.put('"'); dst.escapeString(v); dst.put('"'); },
		(immutable(ubyte)[] v) { dst.put('['); dst.generateBase64(v); dst.put(']'); },
		(int v) { dst.formattedWrite("%s", v); },
		(long v) { dst.formattedWrite("%sL", v); },
		(long[2] v) { assert(false); },
		(float v) { dst.formattedWrite("%sf", v); },
		(double v) { dst.formattedWrite("%s", v); },
		(bool v) { dst.put(v ? "true" : "false"); },
		(SysTime v) {
			auto dt = cast(DateTime)v;
			auto fracsec = v.fracSecs;
			dst.formattedWrite("%d/%02d/%02d %02d:%02d:%02d",
				dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
			dst.writeFracSecs(fracsec.total!"hnsecs");

			if (v.timezone is LocalTime()) {}
			else if (v.timezone is UTC()) dst.put("-UTC");
			else if (auto sz = cast(immutable(SimpleTimeZone))v.timezone) {
				long hours, minutes;
				sz.utcOffset.split!("hours", "minutes")(hours, minutes);
				if (hours < 0 || minutes < 0)
					dst.formattedWrite("-GMT-%02d:%02d", -hours, -minutes); // NOTE: should really be UTC, but we are following the spec here
				else dst.formattedWrite("-GMT+%02d:%02d", hours, minutes);
			} else dst.formattedWrite("-%s", v.timezone.stdName); // Q: should this be name instead (e.g. CEST vs. CET)
		},
		(Date v) { dst.formattedWrite("%d/%02d/%02d", v.year, v.month, v.day); },
		(Duration v) {
			long days, hours, minutes, seconds, hnsecs;
			v.split!("days", "hours", "minutes", "seconds", "hnsecs")
				(days, hours, minutes, seconds, hnsecs);
			if (days > 0) dst.formattedWrite("%sd:", days);
			dst.formattedWrite("%02d:%02d", hours, minutes);
			if (seconds != 0 || hnsecs != 0) {
				dst.formattedWrite(":%02d", seconds);
				dst.writeFracSecs(hnsecs);
			}
		}
	);
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


private void escapeString(R)(ref R dst, in char[] str)
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
	app.escapeString("foo\\bar\r\n\t\tbäz\"");
	assert(app.data == `foo\\bar\r\n\t\tbäz\"`, app.data);
}


private void putIndentation(R)(ref R dst, size_t level)
{
	foreach (i; 0 .. level)
		dst.put('\t');
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

	Base64.encode(bytes[], dst);
}
