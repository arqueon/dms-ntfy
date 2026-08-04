// Pure helpers for the DMS ntfy plugin. Keep this file free of QML state so it
// can also be exercised by the small Node test suite.

function normalizeBaseUrl(value) {
    var url = String(value || "").trim()
    if (url === "")
        return ""
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(url))
        url = "https://" + url
    if (!/^https?:\/\//i.test(url))
        return ""
    return url.replace(/\/+$/, "")
}

function toArray(value) {
    if (!value)
        return []
    if (Array.isArray(value))
        return value.slice()
    if (typeof value.length === "number") {
        var result = []
        for (var i = 0; i < value.length; i++)
            result.push(value[i])
        return result
    }
    return []
}

function parseTopics(value) {
    var candidates = []
    if (Array.isArray(value) || (value && typeof value.length === "number"
                                && typeof value !== "string")) {
        var values = toArray(value)
        for (var i = 0; i < values.length; i++) {
            var item = values[i]
            if (item && typeof item === "object")
                candidates.push(item.topic || item.name || item.value || "")
            else
                candidates.push(item)
        }
    } else {
        candidates = String(value || "").split(/[,\n]/)
    }

    var seen = {}
    var topics = []
    for (var j = 0; j < candidates.length; j++) {
        var topic = String(candidates[j] || "").trim().replace(/^\/+|\/+$/g, "")
        if (topic === "" || topic.indexOf("/") !== -1 || seen[topic])
            continue
        seen[topic] = true
        topics.push(topic)
    }
    return topics
}

function parseInstances(data) {
    var source = data || {}
    var raw = source.instances
    if (typeof raw === "string" && raw.trim() !== "") {
        try {
            raw = JSON.parse(raw)
        } catch (error) {
            raw = []
        }
    }
    var list = []
    var seen = {}
    var candidates = toArray(raw)
    for (var i = 0; i < candidates.length; i++) {
        var item = candidates[i]
        if (!item || typeof item !== "object")
            continue
        var id = String(item.id || "").trim()
        var baseUrl = normalizeBaseUrl(item.baseUrl || "")
        if (id === "" || baseUrl === "" || seen[id])
            continue
        seen[id] = true
        list.push({
            id: id,
            baseUrl: baseUrl,
            topics: parseTopics(item.topics),
            authMethod: String(item.authMethod || "none"),
            username: String(item.username || "").trim(),
            legacySecrets: item.legacySecrets === true
        })
    }
    if (list.length > 0)
        return list

    // Settings written before multi-instance support carry the server at the
    // top level. They become one migrated instance that keeps reading the
    // original un-namespaced keyring entries, so stored secrets keep working.
    var legacyUrl = normalizeBaseUrl(source.baseUrl || "")
    var legacyTopics = parseTopics(source.topics)
    if (legacyUrl === "" || legacyTopics.length === 0)
        return []
    return [{
        id: "main",
        baseUrl: legacyUrl,
        topics: legacyTopics,
        authMethod: String(source.authMethod || "none"),
        username: String(source.username || "").trim(),
        legacySecrets: true
    }]
}

function instanceConfigured(instance) {
    return !!instance
           && instance.baseUrl !== ""
           && instance.topics.length > 0
           && (instance.authMethod !== "basic" || instance.username !== "")
}

function secretKeys(instance, kind) {
    if (!instance)
        return []
    var keys = [kind + ":" + instance.id]
    if (instance.legacySecrets)
        keys.push(kind)
    return keys
}

function instancesContextKey(instances) {
    var parts = []
    var list = toArray(instances)
    for (var i = 0; i < list.length; i++) {
        var instance = list[i]
        parts.push(instance.id + "|" + instance.baseUrl + "|"
                   + instance.topics.join(","))
    }
    return parts.join("&&")
}

function instancesTopics(instances) {
    var merged = []
    var list = toArray(instances)
    for (var i = 0; i < list.length; i++)
        merged = merged.concat(list[i].topics)
    return parseTopics(merged)
}

function combineErrors(errorsById, instances) {
    var list = toArray(instances)
    var parts = []
    for (var i = 0; i < list.length; i++) {
        var message = errorsById ? errorsById[list[i].id] : null
        if (message)
            parts.push(sourceHost(list[i].baseUrl) + ": " + message)
    }
    return parts.join(" · ")
}

function subscriptionUrl(baseUrl, topics, since) {
    var root = normalizeBaseUrl(baseUrl)
    var parsed = parseTopics(topics)
    if (root === "" || parsed.length === 0)
        return ""
    var path = parsed.map(function(topic) {
        return encodeURIComponent(topic)
    }).join(",")
    return root + "/" + path + "/json?poll=1&since="
           + encodeURIComponent(String(since || "all"))
}

function parseCurl(stdout, exitCode) {
    var raw = String(stdout || "")
    if (exitCode !== 0 && raw.trim() === "")
        return {
            status: 0,
            body: "",
            error: exitCode === 67
                   ? "credentials are missing from the system keyring"
                   : "curl exited with code " + exitCode
        }
    var cut = raw.lastIndexOf("\n")
    var statusString = cut >= 0 ? raw.slice(cut + 1).trim() : raw.trim()
    var body = cut >= 0 ? raw.slice(0, cut) : ""
    var status = parseInt(statusString)
    if (isNaN(status))
        return { status: 0, body: body, error: "unreadable curl response" }
    return { status: status, body: body, error: null }
}

function errorText(response) {
    if (!response)
        return "no response"
    if (response.error)
        return response.error
    if (response.status === 0)
        return "could not connect to the ntfy server"
    if (response.status === 400)
        return "the server rejected the subscription request (400)"
    if (response.status === 401)
        return "credentials rejected (401)"
    if (response.status === 403)
        return "access denied for one or more topics (403)"
    if (response.status === 404)
        return "ntfy endpoint not found (404)"
    if (response.status >= 500)
        return "ntfy server error (" + response.status + ")"
    return "HTTP error " + response.status
}

function normalizeAction(action) {
    if (!action || typeof action !== "object")
        return null
    return {
        action: String(action.action || action.type || ""),
        label: String(action.label || action.title || "Action"),
        url: String(action.url || ""),
        method: String(action.method || "POST").toUpperCase(),
        clear: action.clear === true
    }
}

function normalizeAttachment(attachment) {
    if (!attachment || typeof attachment !== "object")
        return null
    return {
        name: String(attachment.name || "attachment"),
        url: String(attachment.url || ""),
        type: String(attachment.type || ""),
        size: parseInt(attachment.size) || 0,
        expires: parseInt(attachment.expires) || 0
    }
}

function messageUid(source, topic, id) {
    return normalizeBaseUrl(source) + "|" + String(topic || "") + "|" + String(id || "")
}

function normalizeMessage(message, source) {
    if (!message || message.event !== "message")
        return null
    var actions = []
    var rawActions = toArray(message.actions)
    for (var i = 0; i < rawActions.length; i++) {
        var action = normalizeAction(rawActions[i])
        if (action)
            actions.push(action)
    }
    var topic = String(message.topic || "")
    var id = String(message.id || "")
    var normalizedSource = normalizeBaseUrl(source)
    return {
        uid: messageUid(normalizedSource, topic, id),
        id: id,
        time: parseInt(message.time) || 0,
        expires: parseInt(message.expires) || 0,
        topic: topic,
        title: String(message.title || ""),
        message: String(message.message || ""),
        priority: Math.max(1, Math.min(5, parseInt(message.priority) || 3)),
        tags: toArray(message.tags).map(String),
        click: String(message.click || ""),
        actions: actions,
        attachment: normalizeAttachment(message.attachment),
        source: normalizedSource,
        sequenceId: String(message.sequence_id || ""),
        read: false
    }
}

function parseNdjson(body, source) {
    var lines = String(body || "").split("\n")
    var messages = []
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line === "")
            continue
        try {
            var normalized = normalizeMessage(JSON.parse(line), source)
            if (normalized)
                messages.push(normalized)
        } catch (error) {
            // A malformed line must not discard the valid messages around it.
        }
    }
    return messages
}

function ensureUid(message) {
    if (!message)
        return ""
    return String(message.uid || messageUid(message.source, message.topic, message.id))
}

function mergeMessages(current, incoming, dismissedUids, limit) {
    var dismissed = {}
    var dismissedList = toArray(dismissedUids)
    for (var d = 0; d < dismissedList.length; d++)
        dismissed[String(dismissedList[d])] = true

    var byUid = {}
    var result = []
    var existing = toArray(current)
    for (var i = 0; i < existing.length; i++) {
        var oldMessage = existing[i]
        var oldUid = ensureUid(oldMessage)
        if (oldUid === "" || dismissed[oldUid] || byUid[oldUid])
            continue
        var migrated = Object.assign({}, oldMessage, {
            uid: oldUid,
            read: oldMessage.read === true
        })
        byUid[oldUid] = migrated
        result.push(migrated)
    }

    var added = []
    var fresh = toArray(incoming)
    for (var j = 0; j < fresh.length; j++) {
        var newMessage = fresh[j]
        var newUid = ensureUid(newMessage)
        if (newUid === "" || dismissed[newUid])
            continue
        if (byUid[newUid]) {
            var previous = byUid[newUid]
            var updated = Object.assign({}, previous, newMessage, {
                uid: newUid,
                read: previous.read === true
            })
            byUid[newUid] = updated
            var oldIndex = result.indexOf(previous)
            if (oldIndex >= 0)
                result[oldIndex] = updated
        } else {
            var inserted = Object.assign({}, newMessage, {
                uid: newUid,
                read: newMessage.read === true
            })
            byUid[newUid] = inserted
            result.push(inserted)
            added.push(inserted)
        }
    }

    result.sort(function(a, b) {
        if ((b.time || 0) !== (a.time || 0))
            return (b.time || 0) - (a.time || 0)
        return String(b.id || "").localeCompare(String(a.id || ""))
    })

    var parsedLimit = parseInt(limit) || 0
    if (parsedLimit > 0 && result.length > parsedLimit)
        result = result.slice(0, parsedLimit)
    return { messages: result, added: added }
}

function newestMessageId(messages, fallback) {
    var list = toArray(messages)
    if (list.length === 0)
        return String(fallback || "")
    var newest = list[0]
    for (var i = 1; i < list.length; i++) {
        if ((list[i].time || 0) >= (newest.time || 0))
            newest = list[i]
    }
    return String(newest.id || fallback || "")
}

function topicList(configuredTopics, messages) {
    var seen = {}
    var result = []
    var configured = parseTopics(configuredTopics)
    for (var i = 0; i < configured.length; i++) {
        seen[configured[i]] = true
        result.push(configured[i])
    }
    var list = toArray(messages)
    for (var j = 0; j < list.length; j++) {
        var topic = String(list[j].topic || "")
        if (topic !== "" && !seen[topic]) {
            seen[topic] = true
            result.push(topic)
        }
    }
    return result
}

function unreadCount(messages, topic) {
    var count = 0
    var selectedTopic = String(topic || "__all__")
    var list = toArray(messages)
    for (var i = 0; i < list.length; i++) {
        if (!list[i].read
                && (selectedTopic === "__all__" || list[i].topic === selectedTopic))
            count++
    }
    return count
}

function matchesSearch(message, query) {
    var q = String(query || "").trim().toLowerCase()
    if (q === "")
        return true
    var haystack = [
        message && message.title,
        message && message.message,
        message && message.topic,
        message && message.source,
        message ? toArray(message.tags).join(" ") : ""
    ].join(" ").toLowerCase()
    return haystack.indexOf(q) !== -1
}

function sourceHost(url) {
    var match = String(url || "").match(/^https?:\/\/([^\/:?#]+)(?::\d+)?/i)
    return match ? match[1] : String(url || "")
}

// Compact per-card label for a server: drops a generic notification prefix
// (ntfy./notify./push.) when a meaningful name remains, then keeps the first
// label. "notify.example.org" -> "example", but "ntfy.sh" stays "ntfy.sh".
function sourceLabel(url) {
    var host = sourceHost(url)
    var labels = host.split(".")
    if (labels.length >= 3 && /^(ntfy|notify|push)$/i.test(labels[0]))
        labels = labels.slice(1)
    if (labels.length < 2 || /^(ntfy|notify|push)$/i.test(labels[0]))
        return host
    return labels[0]
}

function titleOf(message) {
    var title = String(message && message.title || "").trim()
    if (title !== "")
        return title
    return String(message && message.topic || "ntfy")
}

function relativeTime(unixTime) {
    var then = (parseInt(unixTime) || 0) * 1000
    if (then <= 0)
        return ""
    var seconds = Math.max(0, Math.floor((Date.now() - then) / 1000))
    if (seconds < 60)
        return "now"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60)
        return minutes + " min"
    var hours = Math.floor(minutes / 60)
    if (hours < 24)
        return hours + " h"
    var days = Math.floor(hours / 24)
    if (days < 30)
        return days + " d"
    return new Date(then).toLocaleDateString()
}

function fullTime(unixTime) {
    var then = (parseInt(unixTime) || 0) * 1000
    return then > 0 ? new Date(then).toLocaleString() : ""
}

function priorityLabel(priority) {
    var value = parseInt(priority) || 3
    if (value >= 5) return "Urgent"
    if (value === 4) return "High"
    if (value === 2) return "Low"
    if (value <= 1) return "Minimum"
    return "Default"
}

function priorityIcon(priority) {
    var value = parseInt(priority) || 3
    if (value >= 5) return "priority_high"
    if (value === 4) return "keyboard_double_arrow_up"
    if (value === 2) return "keyboard_arrow_down"
    if (value <= 1) return "keyboard_double_arrow_down"
    return "notifications"
}

function formatCount(value) {
    var count = parseInt(value) || 0
    return count > 99 ? "99+" : String(count)
}

function formatBytes(value) {
    var bytes = parseInt(value) || 0
    if (bytes <= 0)
        return ""
    if (bytes < 1024)
        return bytes + " B"
    if (bytes < 1024 * 1024)
        return Math.round(bytes / 1024) + " KB"
    return (bytes / (1024 * 1024)).toFixed(1) + " MB"
}
