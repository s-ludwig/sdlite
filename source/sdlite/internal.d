module sdlite.internal;

import std.traits : Unqual;


package struct MultiAppender(T)
{
	import std.algorithm.comparison : max;

	enum bufferMinSize = max(100, 64*1024 / T.sizeof);

	private {
		Unqual!T[] m_buffer;
		size_t m_base;
		size_t m_fill;
	}

	@disable this(this);

@safe:

	static if (T.sizeof > 2*long.sizeof) {
		void put(ref Unqual!T item)
		{
			reserve(1);
			m_buffer[m_fill++] = cast(Unqual!T)item;
		}
	} else {
		void put(T item)
		{
			reserve(1);
			m_buffer[m_fill++] = cast(Unqual!T)item;
		}

		void put(Unqual!T[] items)
		{
			reserve(items.length);
			m_buffer[m_fill .. m_fill + items.length] = items;
			m_fill += items.length;
		}
	}

	T[] extractArray()
	@trusted {
		auto ret = m_buffer[m_base .. m_fill];
		m_base = m_fill;
		// NOTE: cast to const/immutable is okay here, because this is the only
		//       reference to the returned bytes
		return cast(T[])ret;
	}

	private void reserve(size_t n)
	{
		if (m_fill + n <= m_buffer.length) return;

		if (m_base == 0) {
			m_buffer.length = max(bufferMinSize, m_buffer.length * 2, m_fill + n);
		} else {
			auto newbuf = new Unqual!T[]((m_fill - m_base + n + bufferMinSize - 1) / bufferMinSize * bufferMinSize);
			newbuf[0 .. m_fill - m_base] = m_buffer[m_base .. m_fill];
			m_buffer = newbuf;
			m_fill = m_fill - m_base;
			m_base = 0;
		}
	}
}
