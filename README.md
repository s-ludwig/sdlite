SDLite - a lightweight SDLang parser/generator
==============================================

This library implements a small and efficient parser/generator for [SDLang][1]
documents, providing a range based API. While the parser still uses the GC to
allocate identifiers, strings etc., it uses a very efficient pool based
allocation scheme that has very low computation and memory overhead.

[![DUB Package](https://img.shields.io/dub/v/sdlite.svg)](https://code.dlang.org/packages/sdlite)
[![Build Status](https://travis-ci.org/s-ludwig/sdlite.svg?branch=master)](https://travis-ci.org/s-ludwig/sdlite)
[![codecov](https://codecov.io/gh/s-ludwig/sdlite/branch/master/graph/badge.svg)](https://codecov.io/gh/s-ludwig/sdlite)


Project origins
---------------

The motivation for writing another SDLang implementation for D came from the
high overhead that the original [sdlang-d][2] implementation has. Parsing a
particular 200 MB file took well over 30 seconds and used up almost 10GB of
memory if parsed into a DOM. The following changes to the parsing approach
brought the parsing time down to around 2.5 seconds:

- Using a more efficient allocation scheme
- Using only "native" range implementations instead of the more comfortable
  fiber-based approach taken by sdlang-d
- Using `TaggedUnion` ([taggedalgebraic][3]) instead of `Variant`

Further substantial improvements at this point are more difficult and likely
require the use of bit-level tricks and SIMD for speeding up the lexer, as well
as exploiting the properties of pure array inputs.

[1]: https://sdlang.org/
[2]: https://github.com/Abscissa/SDLang-D
[3]: https://github.com/s-ludwig/taggedalgebraic
