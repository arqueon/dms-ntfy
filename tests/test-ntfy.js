#!/usr/bin/env node

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const helperPath = path.join(__dirname, "..", "JS", "ntfy.js")
const context = {
    Array,
    Date,
    JSON,
    Math,
    Object,
    RegExp,
    String,
    encodeURIComponent
}
vm.createContext(context)
vm.runInContext(fs.readFileSync(helperPath, "utf8"), context, {
    filename: helperPath
})

assert.equal(
    context.normalizeBaseUrl("notify.example.org///"),
    "https://notify.example.org"
)
assert.deepEqual(
    Array.from(context.parseTopics("alerts, system\nalerts,sites-web")),
    ["alerts", "system", "sites-web"]
)
assert.equal(
    context.subscriptionUrl(
        "https://notify.example.org/",
        ["alerts", "sites-web"],
        "abc123"
    ),
    "https://notify.example.org/alerts,sites-web/json?poll=1&since=abc123"
)

const curl = context.parseCurl(
    [
        '{"id":"open","event":"open","topic":"alerts"}',
        '{"id":"m1","time":100,"event":"message","topic":"alerts","title":"Disk","message":"Full","priority":5}',
        "200"
    ].join("\n"),
    0
)
assert.equal(curl.status, 200)

const parsed = Array.from(
    context.parseNdjson(curl.body, "https://notify.example.org"),
    value => ({ ...value, tags: Array.from(value.tags) })
)
assert.equal(parsed.length, 1)
assert.equal(parsed[0].uid, "https://notify.example.org|alerts|m1")
assert.equal(parsed[0].priority, 5)

const existing = [{ ...parsed[0], read: true }]
const update = context.parseNdjson(
    '{"id":"m1","time":100,"event":"message","topic":"alerts","title":"Disk updated","message":"Full"}',
    "https://notify.example.org"
)
const second = context.parseNdjson(
    '{"id":"m2","time":101,"event":"message","topic":"system","message":"Recovered"}',
    "https://notify.example.org"
)
const merged = context.mergeMessages(existing, update.concat(second), [], 0)
assert.equal(merged.messages.length, 2)
assert.equal(merged.added.length, 1)
assert.equal(merged.messages[0].id, "m2")
assert.equal(merged.messages[1].read, true)
assert.equal(merged.messages[1].title, "Disk updated")

const dismissed = context.mergeMessages(
    [],
    second,
    ["https://notify.example.org|system|m2"],
    0
)
assert.equal(dismissed.messages.length, 0)

assert.equal(context.unreadCount(merged.messages, "__all__"), 1)
assert.equal(context.unreadCount(merged.messages, "alerts"), 0)
assert.equal(
    context.matchesSearch(merged.messages[0], "recovered system"),
    true
)
assert.deepEqual(
    Array.from(context.topicList(["alerts"], merged.messages)),
    ["alerts", "system"]
)

console.log("ntfy helper tests: OK")
