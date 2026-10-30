import Testing
@testable import ZagonCore

/// Runs `body` on a scanner over the UTF-8 bytes of `json`.
func scanning<T>(_ json: String, _ body: (inout ByteScanner) -> T) -> T {
    Array(json.utf8).withUnsafeBytes { raw in
        var c = ByteScanner(raw)
        return body(&c)
    }
}

@Suite struct ByteScannerTests {
    @Test func simpleEscapes() {
        #expect(scanning(#""plain""#) { $0.string() } == "plain")
        #expect(scanning(#""a\"b\\c\/d\b\f\n\r\t""#) { $0.string() } == "a\"b\\c/d\u{08}\u{0C}\n\r\t")
        #expect(scanning(#""\\""#) { $0.string() } == "\\")
        #expect(scanning(#""""#) { $0.string() } == "")
        // Raw bytes keep escapes and an escaped quote does not end the string.
        #expect(scanning(#""x\"y""#) { c in c.rawString().map { String(decoding: $0, as: UTF8.self) } } == #"x\"y"#)
    }

    @Test func unicodeEscapes() {
        #expect(scanning(#""é中""#) { $0.string() } == "é中")
        #expect(scanning(#""😀!""#) { $0.string() } == "😀!")
        #expect(scanning(#""é😀""#) { $0.string() } == "é😀")  // raw UTF-8 passes through
        // Lone surrogates become U+FFFD instead of failing.
        #expect(scanning(#""\ud83dx""#) { $0.string() } == "\u{FFFD}x")
        #expect(scanning(#""\ude00""#) { $0.string() } == "\u{FFFD}")
        #expect(scanning(#""\ud83dA""#) { $0.string() } == "\u{FFFD}A")
        // Malformed escapes give nil.
        #expect(scanning(#""\u12""#) { $0.string() } == nil)
        #expect(scanning(#""\u12zz""#) { $0.string() } == nil)
        #expect(scanning(#""\x""#) { $0.string() } == nil)
    }

    @Test func limitTruncatesOnCharacterBoundary() {
        #expect(scanning(#""abcdef""#) { $0.string(limit: 3) } == "abc")
        #expect(scanning(#""a\nbcdef""#) { $0.string(limit: 3) } == "a\nb")
        #expect(scanning(#""ab""#) { $0.string(limit: 10) } == "ab")
        #expect(scanning(#""abc""#) { $0.string(limit: 0) } == "")
        // A cut inside a multi-byte character drops the whole character.
        #expect(scanning(#""aé""#) { $0.string(limit: 2) } == "a")
        #expect(scanning(#""a😀b""#) { $0.string(limit: 4) } == "a")
        #expect(scanning(#""a😀b""#) { $0.string(limit: 5) } == "a😀")
        #expect(scanning(#""\n😀""#) { $0.string(limit: 3) } == "\n")
        #expect(scanning(#""éé""#) { $0.string(limit: 3) } == "é")
        #expect(scanning(#""éé""#) { $0.string(limit: 4) } == "éé")
        #expect(scanning(#""😀""#) { $0.string(limit: 3) } == "")
    }

    @Test func numbersAndLiterals() {
        #expect(scanning("42") { $0.int() } == 42)
        #expect(scanning(" -7 ") { $0.int() } == -7)
        #expect(scanning("1.9") { $0.int() } == 1)
        #expect(scanning("3e2") { $0.int() } == 3)
        #expect(scanning("null") { $0.int() } == nil)
        #expect(scanning(#""5""#) { $0.int() } == nil)
        #expect(scanning("-") { $0.int() } == nil)
        #expect(scanning("99999999999999999999999") { $0.int() } != nil)  // wraps, never traps
        #expect(scanning("1.5") { $0.double() } == 1.5)
        #expect(scanning("-2.25e2") { $0.double() } == -225)
        #expect(scanning("7") { $0.double() } == 7)
        #expect(scanning("null") { $0.double() } == nil)
        #expect(scanning(#""1.5""#) { $0.double() } == nil)
        #expect(scanning("{}") { $0.double() } == nil)
        #expect(scanning("true") { $0.bool() } == true)
        #expect(scanning("false") { $0.bool() } == false)
        #expect(scanning("null") { $0.bool() } == nil)
        #expect(scanning(#""true""#) { $0.bool() } == nil)
        #expect(scanning("") { $0.bool() } == nil)
    }

    @Test func skipValueOverNestedValues() {
        let json = #"[{"a":[1,{"b":"]}\"{["}],"c":{},"d":"\\"}, "s]\"", 1.5e3, true, null, [[]], 5]"#
        var n = 0, last: Int?
        let ok = scanning(json) { c in
            c.array { c in
                n += 1
                if n == 7 { last = c.int(); return last != nil }
                return c.skipValue()
            }
        }
        #expect(ok && n == 7 && last == 5)
        #expect(scanning(#"{"a":"}"} tail"#) { c in c.skipValue() && c.i == 9 })
    }

    @Test func objectReadsWantedKeysAndSkipsOthers() {
        let json = #" { "skip": {"x": ["}", {"y": "\""}]}, "n" : 3, "s":"v", "skip2": [1, 2], "b": false } "#
        var n: Int?, s: String?, b: Bool?
        let ok = scanning(json) { c in
            let r = c.object { c, k in
                if keyIs(k, "n") { n = c.int() } else if keyIs(k, "s") { s = c.string() }
                else if keyIs(k, "b") { b = c.bool() } else { return false }
                return true
            }
            return r && c.atEnd
        }
        #expect(ok && n == 3 && s == "v" && b == false)
        #expect(scanning(#"{"a":1} x"#) { c in c.object { _, _ in false } && !c.atEnd })
        #expect(scanning(" [1] ") { $0.peek } == 0x5B)
        #expect(scanning("   ") { $0.peek } == nil)
    }

    @Test func malformedInputNeverCrashes() {
        let bad = ["", " ", "{", "}", "[", "]", "{\"a\"", "{\"a\":", "{\"a\":1", "{\"a\" 1}", "{a:1}", "[1,2", "\"abc",
                   "\"abc\\", "\"\\u", "{\"a\":\"\\", ",", ":", "{\"a\":[}", "{\"a\":{\"b\":[\"x\"", "nul", "\u{0}", "\"\\ud83d"]
        for s in bad {
            _ = scanning(s) { $0.string() }
            _ = scanning(s) { $0.int() }
            _ = scanning(s) { $0.double() }
            _ = scanning(s) { $0.bool() }
            _ = scanning(s) { $0.skipValue() }
            _ = scanning(s) { $0.array { $0.skipValue() } }
            #expect(scanning(s) { c in c.object { c, _ in c.skipValue() } && c.atEnd } == false, "\(s.debugDescription)")
        }
        // An empty buffer has no base address.
        var c = ByteScanner(UnsafeRawBufferPointer(start: nil, count: 0))
        #expect(c.atEnd && c.peek == nil && c.string() == nil && c.int() == nil && !c.skipValue())
        #expect(!contains(UnsafeRawBufferPointer(start: nil, count: 0), "x"))

        // Every prefix of a real-shaped record, and every single-byte corruption of it, is handled.
        let line = Array(assistantLine(T0, id: "msg_1", input: 3, output: 4, tools: [("toolu_1", "Bash")]).utf8)
        for k in 0...line.count {
            _ = Array(line[0..<k]).withUnsafeBytes { ClaudeParser.scan($0, wantText: true) }
        }
        for k in stride(from: 0, to: line.count, by: 3) {
            for v: UInt8 in [0x22, 0x5C, 0x7B, 0x7D, 0x5B, 0x5D, 0x00, 0xFF] {
                var b = line; b[k] = v
                _ = b.withUnsafeBytes { ClaudeParser.scan($0, wantText: true) }
            }
        }
    }

    @Test func helpers() {
        Array("type".utf8).withUnsafeBytes { k in
            #expect(keyIs(k, "type") && !keyIs(k, "typ") && !keyIs(k, "types"))
        }
        Array(#"{"type":"user"}"#.utf8).withUnsafeBytes { b in
            #expect(contains(b, "\"type\":\"user\"") && !contains(b, "\"type\":\"assistant\""))
        }
        #expect(fnv1a64("") == Int64(bitPattern: 0xcbf29ce484222325))
        #expect(fnv1a64("a") == Int64(bitPattern: 0xaf63dc4c8601ec8c))
    }
}
