// node tests/run.js — tests the pure helpers in GrammarCheck.js.
const fs = require("fs")
const path = require("path")
const assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "GrammarCheck.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const module_ = { exports: {} }
new Function("module", src)(module_)
const GC = module_.exports

let n = 0
function t(name, fn) { fn(); n++; console.log("ok", name) }

t("config parsing ignores unknown keys and shell syntax", () => {
  const c = GC.parseConfig('LT_USERNAME="me@x.be"\nLT_API_KEY=\'abc\'\nPATH="/evil"\nLT_LEVEL=picky # comment\nLT_LANGUAGE="$(rm -rf ~)"\n')
  assert.strictEqual(c.LT_USERNAME, "me@x.be")
  assert.strictEqual(c.LT_API_KEY, "abc")
  assert.strictEqual(c.PATH, undefined)
  assert.strictEqual(c.LT_LEVEL, "picky")
  assert.strictEqual(c.LT_LANGUAGE, "$(rm -rf ~)")
  assert.ok(!GC.validLanguage(c.LT_LANGUAGE))
})

t("endpoint: free, premium, custom", () => {
  assert.deepStrictEqual(GC.endpoint({}), { url: "https://api.languagetool.org/v2/check", sendCredentials: false, custom: false })
  assert.strictEqual(GC.endpoint({ LT_USERNAME: "a", LT_API_KEY: "b" }).sendCredentials, true)
  const local = GC.endpoint({ LT_SERVER: "http://localhost:8081", LT_USERNAME: "a", LT_API_KEY: "b" })
  assert.strictEqual(local.url, "http://localhost:8081/v2/check")
  assert.strictEqual(local.sendCredentials, false)
  assert.ok(GC.endpoint({ LT_SERVER: "http://example.com" }).error)
  assert.ok(GC.endpoint({ LT_SERVER: "http://localhost.evil.com" }).error)
  assert.ok(GC.endpoint({ LT_SERVER: "https://user:pw@example.com" }).error)
  assert.ok(GC.endpoint({ LT_SERVER: "javascript:alert(1)" }).error)
  assert.ok(GC.endpoint({ LT_SERVER: "file:///etc/passwd" }).error)
  assert.strictEqual(GC.endpoint({ LT_SERVER: "https://lt.example.com/v2/check" }).url, "https://lt.example.com/v2/check")
})

t("form body encodes and drops invalid parameters", () => {
  const ep = { sendCredentials: true }
  const body = GC.formBody("a&b=c ü", { LT_LANGUAGE: "x&apiKey=1", LT_LEVEL: "evil", LT_USERNAME: "u", LT_API_KEY: "k&x" }, ep)
  const p = new URLSearchParams(body)
  assert.strictEqual(p.get("text"), "a&b=c ü")
  assert.strictEqual(p.get("language"), "auto")
  assert.strictEqual(p.get("level"), "default")
  assert.strictEqual(p.get("apiKey"), "k&x")
  assert.strictEqual(p.getAll("apiKey").length, 1)
  const free = new URLSearchParams(GC.formBody("x", { LT_USERNAME: "u", LT_API_KEY: "k" }, { sendCredentials: false }))
  assert.strictEqual(free.get("apiKey"), null)
  assert.strictEqual(free.get("username"), null)
})

t("parseMatches drops out-of-range and malformed matches, and overlaps", () => {
  const text = "ik wordt gebelt"
  const r = GC.parseMatches(JSON.stringify({ language: { name: "Dutch (Belgium)" }, matches: [
    { offset: 9, length: 6, message: "Spelling", replacements: [{ value: "gebeld" }] },
    { offset: 0, length: 8, message: "Verb", replacements: [{ value: "ik word" }, { value: 5 }] },
    { offset: 3, length: 2, message: "overlap", replacements: [] },
    { offset: 14, length: 99, message: "out of range" },
    { offset: -1, length: 1 },
    { offset: "1", length: 1 },
    null
  ] }), text)
  assert.strictEqual(r.language, "Dutch (Belgium)")
  assert.deepStrictEqual(r.matches.map(m => m.offset), [0, 9])
  assert.deepStrictEqual(r.matches[0].suggestions, ["ik word"])
})

t("applyFix shifts later offsets; applyAll keeps unfixable matches aligned", () => {
  const text = "ik wordt gebelt en zo"
  const ms = GC.parseMatches({ matches: [
    { offset: 0, length: 8, replacements: [{ value: "ik word" }] },
    { offset: 9, length: 6, replacements: [{ value: "gebeld" }] },
    { offset: 19, length: 2, replacements: [] }
  ] }, text).matches
  const one = GC.applyFix(text, ms, 0, "ik word")
  assert.strictEqual(one.text, "ik word gebelt en zo")
  assert.strictEqual(one.text.slice(one.matches[0].offset, one.matches[0].offset + 6), "gebelt")
  const all = GC.applyAll(text, ms)
  assert.strictEqual(all.text, "ik word gebeld en zo")
  assert.strictEqual(all.applied, 2)
  assert.strictEqual(all.text.slice(all.matches[0].offset, all.matches[0].offset + 2), "zo")
})

t("UTF-16 offsets with emoji", () => {
  const text = "😀 smple"
  const ms = GC.parseMatches({ matches: [{ offset: 3, length: 5, replacements: [{ value: "simple" }] }] }, text).matches
  assert.strictEqual(GC.applyAll(text, ms).text, "😀 simple")
})

t("highlight escapes markup in text and suggestions", () => {
  const text = '<img src="http://evil/x.png"> & <a href=x>teh</a>'
  const i = text.indexOf("teh")
  const out = GC.highlight(text, [{ offset: i, length: 3 }], 0, "#ff0000", 'red" onload="x')
  assert.ok(!/<img|<a /.test(out), out)
  assert.ok(out.includes("&lt;img"))
  assert.ok(out.includes('color="#ff5555"'))
  assert.ok(!out.includes("onload"))
})

t("looseMode", () => {
  assert.strictEqual(GC.looseMode("600\n"), false)
  assert.strictEqual(GC.looseMode("644"), true)
  assert.strictEqual(GC.looseMode("640"), true)
  assert.strictEqual(GC.looseMode("700"), false)
})

t("marksSecret", () => {
  assert.strictEqual(GC.marksSecret("text/plain\nx-kde-passwordManagerHint\n"), true)
  assert.strictEqual(GC.marksSecret("text/plain\nUTF8_STRING\n"), false)
})

t("unsafe suggestions are dropped, messages cleaned", () => {
  const r = GC.parseMatches({ language: { name: "En\u202Eglish" }, matches: [{ offset: 0, length: 3, message: "bad\nline\u0007",
    replacements: [{ value: "the\nrm -rf ~\n" }, { value: "t\u202Ehe" }, { value: "the\tx" }, { value: "the" }, { value: "x".repeat(600) }] }] }, "teh")
  assert.deepStrictEqual(r.matches[0].suggestions, ["the"])
  assert.ok(!/[\n\u0007]/.test(r.matches[0].message))
  assert.ok(!/\u202E/.test(r.language))
})

console.log(n + " tests passed")
