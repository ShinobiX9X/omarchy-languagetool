.pragma library

// Pure helpers for the grammar check overlay. Nothing here touches the
// network, the clipboard or the filesystem, so it can be tested with node
// (see tests/run.js).

var OFFICIAL_FREE = "https://api.languagetool.org/v2/check"
var OFFICIAL_PREMIUM = "https://api.languagetoolplus.com/v2/check"

var MAX_TEXT = 60000          // characters sent per check
var MAX_MATCHES = 500
var MAX_SUGGESTIONS = 9       // one per number key
var MAX_FIELD = 500           // longest message/suggestion we keep

var CONFIG_KEYS = {
  LT_USERNAME: true, LT_API_KEY: true, LT_LANGUAGE: true,
  LT_PREFERRED_VARIANTS: true, LT_MOTHER_TONGUE: true, LT_LEVEL: true,
  LT_SERVER: true
}

// Reads KEY="value" lines. The file is never sourced by a shell, so anything
// clever in it stays a plain string.
function parseConfig(raw) {
  var conf = { LT_LANGUAGE: "auto", LT_LEVEL: "default" }
  var lines = String(raw || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/.exec(lines[i])
    if (!m || !CONFIG_KEYS[m[1]]) continue
    var value = m[2]
    var q = /^"([^"]*)"$/.exec(value) || /^'([^']*)'$/.exec(value)
    if (q) value = q[1]
    else value = value.replace(/\s+#.*$/, "")
    conf[m[1]] = value
  }
  return conf
}

// Language tags and levels go into the request as-is, so only accept the
// shapes LanguageTool documents.
function validLanguage(tag) {
  return tag === "auto" || /^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/.test(tag)
}

function validVariants(list) {
  if (!list) return true
  var parts = list.split(",")
  for (var i = 0; i < parts.length; i++)
    if (parts[i] === "auto" || !validLanguage(parts[i])) return false
  return true
}

// Returns { url, sendCredentials } or { error }. A custom server is only
// allowed over https, or plain http to this machine. Credentials only ever go
// to the official Premium host, never to a custom server.
function endpoint(conf) {
  var server = conf.LT_SERVER || ""
  if (server) {
    var m = /^(https?):\/\/([^\/?#@\s]+)(\/[^?#\s]*)?$/.exec(server)
    if (!m) return { error: "LT_SERVER is not a valid http(s) URL" }
    var host = m[2].toLowerCase().replace(/:\d+$/, "")
    var local = host === "localhost" || host === "127.0.0.1" || host === "[::1]"
    if (m[1] === "http" && !local)
      return { error: "LT_SERVER must use https (plain http is only allowed for localhost)" }
    var base = server.replace(/\/+$/, "")
    if (!/\/v2\/check$/.test(base)) base += "/v2/check"
    return { url: base, sendCredentials: false, custom: true }
  }
  if (conf.LT_USERNAME && conf.LT_API_KEY)
    return { url: OFFICIAL_PREMIUM, sendCredentials: true, custom: false }
  return { url: OFFICIAL_FREE, sendCredentials: false, custom: false }
}

function formBody(text, conf, ep) {
  var params = [
    ["text", text],
    ["language", validLanguage(conf.LT_LANGUAGE) ? conf.LT_LANGUAGE : "auto"],
    ["level", conf.LT_LEVEL === "picky" ? "picky" : "default"]
  ]
  if ((conf.LT_LANGUAGE || "auto") === "auto" && conf.LT_PREFERRED_VARIANTS && validVariants(conf.LT_PREFERRED_VARIANTS))
    params.push(["preferredVariants", conf.LT_PREFERRED_VARIANTS])
  if (conf.LT_MOTHER_TONGUE && validLanguage(conf.LT_MOTHER_TONGUE) && conf.LT_MOTHER_TONGUE !== "auto")
    params.push(["motherTongue", conf.LT_MOTHER_TONGUE])
  if (ep.sendCredentials) {
    params.push(["username", conf.LT_USERNAME])
    params.push(["apiKey", conf.LT_API_KEY])
  }
  return params.map(function (p) {
    return encodeURIComponent(p[0]) + "=" + encodeURIComponent(p[1])
  }).join("&")
}

// Control characters (newlines included) and bidi overrides. A suggestion with
// one of these is dropped: pasted into a terminal a newline can run a command,
// and bidi overrides can hide what is really pasted ("Trojan Source").
var UNSAFE = /[\u0000-\u001F\u007F-\u009F\u200E\u200F\u202A-\u202E\u2066-\u2069]/

function safeSuggestion(value) {
  return typeof value === "string" && !UNSAFE.test(value)
}

function displayText(s) {
  return String(s).replace(new RegExp(UNSAFE.source, "g"), " ")
}

function clip(s, n) {
  s = String(s === undefined || s === null ? "" : s)
  return s.length > n ? s.slice(0, n - 1) + "…" : s
}

// Turns the API reply into a small, checked list. Offsets are UTF-16 units,
// which is exactly how JS strings index, so they apply to `text` directly.
// Anything malformed or out of range is dropped rather than trusted.
function parseMatches(json, text) {
  var data = typeof json === "string" ? JSON.parse(json) : json
  var raw = data && Array.isArray(data.matches) ? data.matches : []
  var out = []
  for (var i = 0; i < raw.length && out.length < MAX_MATCHES; i++) {
    var m = raw[i] || {}
    var offset = m.offset, length = m.length
    if (!Number.isInteger(offset) || !Number.isInteger(length)) continue
    if (offset < 0 || length < 0 || offset + length > text.length) continue
    var suggestions = []
    var reps = Array.isArray(m.replacements) ? m.replacements : []
    for (var j = 0; j < reps.length && suggestions.length < MAX_SUGGESTIONS; j++) {
      var value = reps[j] && reps[j].value
      if (safeSuggestion(value) && value.length <= MAX_FIELD)
        suggestions.push(value)
    }
    out.push({
      offset: offset,
      length: length,
      message: displayText(clip(m.message, MAX_FIELD)),
      rule: displayText(clip(m.rule && m.rule.category && m.rule.category.name, 80)),
      suggestions: suggestions
    })
  }
  out.sort(function (a, b) { return a.offset - b.offset })
  // Overlapping ranges cannot both be applied; keep the first.
  var clean = []
  var end = -1
  for (var k = 0; k < out.length; k++) {
    if (out[k].offset < end) continue
    clean.push(out[k])
    end = out[k].offset + out[k].length
  }
  var lang = data && data.language && typeof data.language.name === "string" ? displayText(clip(data.language.name, 60)) : ""
  return { language: lang, matches: clean }
}

// Applies one replacement and returns the new text plus matches whose
// offsets follow the edit. The applied match is removed.
function applyFix(text, matches, index, replacement) {
  var m = matches[index]
  var delta = replacement.length - m.length
  var next = text.slice(0, m.offset) + replacement + text.slice(m.offset + m.length)
  var rest = []
  for (var i = 0; i < matches.length; i++) {
    if (i === index) continue
    var o = matches[i]
    if (o.offset >= m.offset + m.length) rest.push(shift(o, delta))
    else rest.push(o)
  }
  return { text: next, matches: rest }
}

// First suggestion for every match that has one; matches without a suggestion
// stay, moved to their new offsets.
function applyAll(text, matches) {
  var out = ""
  var pos = 0
  var delta = 0
  var kept = []
  var applied = 0
  for (var i = 0; i < matches.length; i++) {
    var m = matches[i]
    out += text.slice(pos, m.offset)
    if (m.suggestions.length > 0) {
      out += m.suggestions[0]
      delta += m.suggestions[0].length - m.length
      applied++
    } else {
      out += text.slice(m.offset, m.offset + m.length)
      kept.push(shift(m, delta))
    }
    pos = m.offset + m.length
  }
  out += text.slice(pos)
  return { text: out, matches: kept, applied: applied }
}

function shift(m, delta) {
  return { offset: m.offset + delta, length: m.length, message: m.message, rule: m.rule, suggestions: m.suggestions }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

// StyledText markup for the preview: every piece of user or API text is
// escaped, so the only tags in the output are the ones written here.
function highlight(text, matches, current, errorColor, currentColor) {
  var out = ""
  var pos = 0
  for (var i = 0; i < matches.length; i++) {
    var m = matches[i]
    out += escapeHtml(text.slice(pos, m.offset))
    var word = escapeHtml(text.slice(m.offset, m.offset + m.length)) || "&nbsp;"
    if (i === current)
      out += '<b><u><font color="' + safeColor(currentColor) + '">' + word + "</font></u></b>"
    else
      out += '<u><font color="' + safeColor(errorColor) + '">' + word + "</font></u>"
    pos = m.offset + m.length
  }
  out += escapeHtml(text.slice(pos))
  return out.replace(/\n/g, "<br>")
}

function safeColor(c) {
  c = String(c)
  return /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(c) ? c : "#ff5555"
}

// Password managers (KeePassXC, Bitwarden, 1Password, …) offer this MIME
// type alongside a copied secret; such text is never sent.
function marksSecret(types) {
  return /^x-kde-passwordManagerHint$/m.test(String(types))
}

// Group or other access to the key file, from `stat -c %a`.
function looseMode(mode) {
  var m = /^[0-7]*([0-7])([0-7])$/.exec(String(mode).trim())
  return !!m && (m[1] !== "0" || m[2] !== "0")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseConfig: parseConfig, validLanguage: validLanguage, validVariants: validVariants,
    endpoint: endpoint, formBody: formBody, parseMatches: parseMatches, applyFix: applyFix, applyAll: applyAll,
    escapeHtml: escapeHtml, highlight: highlight, safeColor: safeColor, looseMode: looseMode, marksSecret: marksSecret, safeSuggestion: safeSuggestion, displayText: displayText,
    MAX_TEXT: MAX_TEXT
  }
}
