/** Types for holding SDLang document data.
*/
module sdlite.ast;

import taggedalgebraic.taggedunion;
import std.datetime;
import std.string : indexOf;

@safe pure:

void validateQualifiedIdentiifier(string qualified_ident)
{
	auto idx = qualified_ident.indexOf(':');
	if (idx >= 0) {
		if (qualified_ident[idx+1 .. $].indexOf(':') >= 0)
			throw new Exception("Multiple namespace separators in identifier: "~qualified_ident);
		validateIdentifier(qualified_ident[0 .. idx]);
		validateIdentifier(qualified_ident[idx+1 .. $]);
	} else validateIdentifier(qualified_ident);
}

void validateIdentifier(string ident)
{
	// TODO
}


/** Represents a single SDL node.
*/
struct SDLNode {
	private string m_qualifiedName;
	SDLValue[] values;
	SDLAttribute[] attributes;
	SDLNode[] children;

	this(string qualified_name, SDLValue[] values = null,
		SDLAttribute[] attributes = null, SDLNode[] children = null)
	{
		this.qualifiedName = qualified_name;
		this.values = values;
		this.attributes = attributes;
		this.children = children;
	}

@safe pure:
	/** Qualified name of the tag

		The form of this value is either "namespace:name" or just "name".
	*/
	@property string qualifiedName() const nothrow { return m_qualifiedName; }
	/// ditto
	@property void qualifiedName(string qualified_ident)
	{
		validateQualifiedIdentiifier(qualified_ident);
		m_qualifiedName = qualified_ident;
	}


	/// Namespace (if any) of the tag
	@property string namespace()
	const nothrow {
		auto idx = m_qualifiedName.indexOf(':');
		if (idx >= 0) return m_qualifiedName[0 .. idx];
		return null;
	}

	/// Unqualified name of the tag (use `namespace` to disambiguate)
	@property string name()
	const nothrow {
		auto idx = m_qualifiedName.indexOf(':');
		if (idx >= 0) return m_qualifiedName[idx+1 .. $];
		return m_qualifiedName;
	}

	/// Looks up an attribute by qualified name
	SDLValue getAttribute(string qualified_name, SDLValue default_ = SDLValue.null_)
	nothrow {
		foreach (ref a; attributes)
			if (a.qualifiedName == qualified_name)
				return a.value;
		return default_;
	}
}


/** Attribute of a node
*/
struct SDLAttribute {
	private string m_qualifiedName;

	SDLValue value;

@safe pure:
	this(string qualified_ident, SDLValue value)
	{
		this.qualifiedName = qualified_ident;
		this.value = value;
	}

	/** Qualified name of the attribute

		The form of this value is either "namespace:name" or just "name".
	*/
	@property string qualifiedName() const nothrow { return m_qualifiedName; }
	/// ditto
	@property void qualifiedName(string qualified_ident)
	{
		validateQualifiedIdentiifier(qualified_ident);
		m_qualifiedName = qualified_ident;
	}

	/// Namespace (if any) of the attribute
	@property string namespace()
	const nothrow {
		auto idx = m_qualifiedName.indexOf(':');
		if (idx >= 0) return m_qualifiedName[0 .. idx];
		return null;
	}

	/// Unqualified name of the attribute (use `namespace` to disambiguate)
	@property string name()
	const nothrow {
		auto idx = m_qualifiedName.indexOf(':');
		if (idx >= 0) return m_qualifiedName[idx+1 .. $];
		return m_qualifiedName;
	}
}


/** A single SDLang value
*/
alias SDLValue = TaggedUnion!SDLValueFields;

struct SDLValueFields {
	Void null_;
	string text;
	immutable(ubyte)[] binary;
	int int_;
	long long_;
	long[2] decimal;
	float float_;
	double double_;
	bool bool_;
	SysTime dateTime;
	Date date;
	Duration duration;
}
