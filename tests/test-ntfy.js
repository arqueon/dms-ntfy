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

// Multi-instance helpers.

const migrated = context.parseInstances({
    baseUrl: "notify.example.org",
    topics: "alerts,system",
    authMethod: "token",
    username: ""
})
assert.equal(migrated.length, 1)
assert.equal(migrated[0].id, "main")
assert.equal(migrated[0].baseUrl, "https://notify.example.org")
assert.deepEqual(Array.from(migrated[0].topics), ["alerts", "system"])
assert.equal(migrated[0].legacySecrets, true)
assert.deepEqual(
    Array.from(context.secretKeys(migrated[0], "token")),
    ["token:main", "token"]
)

const multi = context.parseInstances({
    instances: [
        { id: "main", baseUrl: "https://notify.example.org", topics: "alerts",
          authMethod: "token", legacySecrets: true },
        { id: "btb", baseUrl: "notify.btb.org/", topics: ["centinela", "btb"],
          authMethod: "basic", username: "ruben" },
        { id: "", baseUrl: "https://ignored.example.org", topics: "x" },
        { id: "btb", baseUrl: "https://duplicate.example.org", topics: "y" }
    ],
    baseUrl: "https://legacy-ignored.example.org",
    topics: "legacy"
})
assert.equal(multi.length, 2)
assert.equal(multi[1].baseUrl, "https://notify.btb.org")
assert.deepEqual(
    Array.from(context.secretKeys(multi[1], "password")),
    ["password:btb"]
)
assert.equal(context.instanceConfigured(multi[0]), true)
assert.equal(
    context.instanceConfigured({ id: "x", baseUrl: "https://x.org",
                                 topics: ["a"], authMethod: "basic",
                                 username: "" }),
    false
)
assert.deepEqual(
    Array.from(context.instancesTopics(multi)),
    ["alerts", "centinela", "btb"]
)
assert.equal(
    context.instancesContextKey(multi),
    "main|https://notify.example.org|alerts"
    + "&&btb|https://notify.btb.org|centinela,btb"
)
assert.equal(
    context.combineErrors({ btb: "credentials rejected (401)" }, multi),
    "notify.btb.org: credentials rejected (401)"
)
assert.equal(context.combineErrors({}, multi), "")

// Instances parsed from a JSON string (settings written by older tooling).
const fromString = context.parseInstances({
    instances: JSON.stringify([
        { id: "a", baseUrl: "https://a.example.org", topics: "t1" }
    ])
})
assert.equal(fromString.length, 1)
assert.equal(fromString[0].id, "a")

// No configuration at all yields no instances.
assert.deepEqual(Array.from(context.parseInstances({})), [])

assert.equal(context.sourceLabel("https://notify.arqueonautis.org"), "arqueonautis")
assert.equal(
    context.sourceLabel("https://notify.barbiestesteadoras.org"),
    "barbiestesteadoras"
)
assert.equal(context.sourceLabel("https://ntfy.sh"), "ntfy.sh")
assert.equal(context.sourceLabel("https://push.corp.example.com"), "corp")
assert.equal(context.sourceLabel("http://localhost:8098"), "localhost")

// Topic discovery from /v1/account: union of same-server subscriptions and
// reservations, deduplicated; foreign-server subscriptions are excluded.
assert.equal(
    context.accountUrl("notify.example.org/"),
    "https://notify.example.org/v1/account"
)
assert.equal(context.accountUrl(""), "")
assert.deepEqual(
    Array.from(context.accountTopics(JSON.stringify({
        username: "ruben",
        subscriptions: [
            { base_url: "https://notify.example.org", topic: "alerts" },
            { base_url: "https://ntfy.sh", topic: "foreign" },
            { topic: "backups" }
        ],
        reservations: [
            { topic: "alerts", everyone: "deny-all" },
            { topic: "system", everyone: "read-only" }
        ]
    }), "notify.example.org")),
    ["alerts", "backups", "system"]
)
// An account with nothing attached yields an empty list, not an error.
assert.deepEqual(
    Array.from(context.accountTopics('{"username":"*"}', "https://x.org")),
    []
)
// Broken payloads surface as null so the UI can tell "empty" from "unreadable".
assert.equal(context.accountTopics("not json", "https://x.org"), null)
assert.equal(context.accountTopics('"just a string"', "https://x.org"), null)
// The shared curl recipe keeps the secret off argv: it must read the keyring
// and pipe the header through stdin.
assert.ok(context.AUTH_CURL_SCRIPT.indexOf("secret-tool lookup") !== -1)
assert.ok(context.AUTH_CURL_SCRIPT.indexOf("-H @-") !== -1)

console.log("ntfy helper tests: OK")
