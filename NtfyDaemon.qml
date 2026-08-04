// NtfyDaemon.qml — one long-lived poller and persistent archive for all bar
// instances. The widget surface only reads global state and sends mutations
// back here over DMS IPC, so horizontal and vertical bars never double-poll.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import "./JS/ntfy.js" as Ntfy

PluginComponent {
    id: root

    property var popoutService: null

    // Settings (PluginComponent.pluginData is reactive). Legacy single-server
    // settings are folded into a one-element instance list by parseInstances.
    property var instances: Ntfy.parseInstances(pluginData)
    property var configuredTopics: Ntfy.instancesTopics(instances)
    property int pollIntervalMs: Math.max(15, parseInt(pluginData.pollInterval) || 60) * 1000
    property int historyLimit: Math.max(0, parseInt(pluginData.historyLimit) || 0)
    property string secretsStamp: String(pluginData.secretsStamp || "")

    readonly property string contextKey: Ntfy.instancesContextKey(instances)
    readonly property bool configured: instances.some(Ntfy.instanceConfigured)

    // Persistent archive state. cursors maps instance id to its own
    // { cursor, context } pair so each server resumes where it left off.
    property var messages: []
    property var dismissedUids: []
    property var cursors: ({})
    property double lastUpdated: 0

    // Runtime state shared with every widget surface.
    property bool stateLoaded: false
    property int pendingRequests: 0
    readonly property bool isLoading: pendingRequests > 0
    property var instanceErrors: ({})
    property string errorMessage: ""
    property int requestSequence: 0

    // The auth curl recipe lives in ntfy.js (AUTH_CURL_SCRIPT) so the
    // settings' topic discovery reuses it verbatim.
    readonly property string authenticatedCurlScript: Ntfy.AUTH_CURL_SCRIPT

    function _archiveObject() {
        return {
            version: 2,
            messages: messages,
            dismissedUids: dismissedUids,
            cursors: cursors,
            lastUpdated: lastUpdated
        }
    }

    function persistArchive() {
        pluginService?.savePluginState(pluginId, "archive", _archiveObject())
    }

    function publishRuntime() {
        if (!pluginService)
            return
        pluginService.setGlobalVar(pluginId, "messages", messages)
        pluginService.setGlobalVar(pluginId, "unreadCount", Ntfy.unreadCount(messages, "__all__"))
        pluginService.setGlobalVar(pluginId, "topics", Ntfy.topicList(configuredTopics, messages))
        pluginService.setGlobalVar(pluginId, "configured", configured)
        pluginService.setGlobalVar(pluginId, "instances", instances)
        pluginService.setGlobalVar(pluginId, "loading", isLoading)
        pluginService.setGlobalVar(pluginId, "errorMessage", errorMessage)
        pluginService.setGlobalVar(pluginId, "lastUpdated", lastUpdated)
    }

    function _instanceCursor(instanceId) {
        var entry = cursors ? cursors[instanceId] : null
        if (!entry)
            return ""
        return String(entry.cursor || "")
    }

    function _setInstanceCursor(instanceId, cursorValue, context) {
        var next = {}
        for (var key in cursors)
            next[key] = cursors[key]
        next[instanceId] = { cursor: String(cursorValue || ""), context: context }
        cursors = next
    }

    function loadArchive() {
        var saved = pluginService
                    ? pluginService.loadPluginState(pluginId, "archive", {})
                    : {}
        messages = saved ? Ntfy.toArray(saved.messages) : []
        dismissedUids = saved ? Ntfy.toArray(saved.dismissedUids) : []
        lastUpdated = saved ? parseInt(saved.lastUpdated) || 0 : 0

        var loadedCursors = saved && saved.cursors && typeof saved.cursors === "object"
                            ? saved.cursors : {}
        // Version 1 archives kept one global cursor; it belongs to the
        // migrated legacy instance when its context still matches.
        if (saved && saved.cursor && instances.length > 0
                && String(saved.cursorContext || "")
                   === instances[0].baseUrl + "|" + instances[0].topics.join(",")) {
            loadedCursors = {}
            loadedCursors[instances[0].id] = {
                cursor: String(saved.cursor),
                context: _instanceContext(instances[0])
            }
        }
        // Drop cursors whose instance configuration changed.
        var valid = {}
        for (var i = 0; i < instances.length; i++) {
            var instance = instances[i]
            var entry = loadedCursors[instance.id]
            if (entry && String(entry.context || "") === _instanceContext(instance))
                valid[instance.id] = entry
        }
        cursors = valid
        stateLoaded = true
        publishRuntime()
    }

    function _instanceContext(instance) {
        return instance.baseUrl + "|" + instance.topics.join(",")
    }

    function _curlArguments(instance, url) {
        if (instance.authMethod === "none") {
            return [
                "curl", "-sS", "--max-time", "25",
                "-w", "\n%{http_code}", url
            ]
        }
        var keys = Ntfy.secretKeys(instance, instance.authMethod === "token"
                                   ? "token" : "password")
        return [
            "sh", "-c", authenticatedCurlScript, "dms-ntfy",
            instance.authMethod, instance.username, url,
            keys[0] || "", keys[1] || ""
        ]
    }

    function fetchMessages() {
        if (!stateLoaded || !configured || isLoading)
            return
        instanceErrors = {}
        errorMessage = ""
        for (var i = 0; i < instances.length; i++) {
            var instance = instances[i]
            if (!Ntfy.instanceConfigured(instance))
                continue
            pendingRequests++
            var since = _instanceCursor(instance.id)
            _requestInstance(instance, since !== "" ? since : "all", true)
        }
        publishRuntime()
    }

    function _finishRequest() {
        pendingRequests = Math.max(0, pendingRequests - 1)
        if (pendingRequests === 0) {
            errorMessage = Ntfy.combineErrors(instanceErrors, instances)
            persistArchive()
        }
        publishRuntime()
    }

    function _requestInstance(instance, since, allowFallback) {
        var url = Ntfy.subscriptionUrl(instance.baseUrl, instance.topics, since)
        if (url === "") {
            instanceErrors[instance.id] = "invalid URL or topics"
            _finishRequest()
            return
        }
        Proc.runCommand(
            "ntfy.fetch." + instance.id + "." + (++requestSequence),
            _curlArguments(instance, url),
            (stdout, exitCode) => {
                var response = Ntfy.parseCurl(stdout, exitCode)
                if (allowFallback && since !== "all" && response.status === 400) {
                    _setInstanceCursor(instance.id, "", _instanceContext(instance))
                    _requestInstance(instance, "all", false)
                    return
                }

                if (response.status !== 200) {
                    instanceErrors[instance.id] = Ntfy.errorText(response)
                    _finishRequest()
                    return
                }

                var incoming = Ntfy.parseNdjson(response.body, instance.baseUrl)
                var merged = Ntfy.mergeMessages(
                    messages,
                    incoming,
                    dismissedUids,
                    historyLimit
                )
                messages = merged.messages
                _setInstanceCursor(
                    instance.id,
                    Ntfy.newestMessageId(incoming, _instanceCursor(instance.id)),
                    _instanceContext(instance)
                )
                lastUpdated = Date.now()
                _finishRequest()
            }
        )
    }

    function setRead(uid, readValue) {
        var wanted = String(uid || "")
        if (wanted === "")
            return false
        var changed = false
        var next = []
        for (var i = 0; i < messages.length; i++) {
            var message = messages[i]
            if (message.uid === wanted && message.read !== readValue) {
                next.push(Object.assign({}, message, { read: readValue }))
                changed = true
            } else {
                next.push(message)
            }
        }
        if (changed) {
            messages = next
            persistArchive()
            publishRuntime()
        }
        return changed
    }

    function _uidSet(uidList) {
        var parts = String(uidList || "").split("\n")
        var wanted = {}
        for (var i = 0; i < parts.length; i++) {
            var uid = parts[i].trim()
            if (uid !== "")
                wanted[uid] = true
        }
        return wanted
    }

    function setReadMany(uidList, readValue) {
        var wanted = _uidSet(uidList)
        var changed = 0
        var next = []
        for (var i = 0; i < messages.length; i++) {
            var message = messages[i]
            if (wanted[message.uid] && message.read !== readValue) {
                next.push(Object.assign({}, message, { read: readValue }))
                changed++
            } else {
                next.push(message)
            }
        }
        if (changed > 0) {
            messages = next
            persistArchive()
            publishRuntime()
        }
        return changed
    }

    function dismissMany(uidList) {
        var wanted = _uidSet(uidList)
        var removed = []
        var kept = []
        for (var i = 0; i < messages.length; i++) {
            var message = messages[i]
            if (wanted[message.uid])
                removed.push(message.uid)
            else
                kept.push(message)
        }
        if (removed.length === 0)
            return 0
        messages = kept
        var tombstones = dismissedUids.slice()
        for (var j = 0; j < removed.length; j++) {
            if (tombstones.indexOf(removed[j]) === -1)
                tombstones.push(removed[j])
        }
        dismissedUids = tombstones
        persistArchive()
        publishRuntime()
        return removed.length
    }

    function markAllRead(topic) {
        var selectedTopic = String(topic || "__all__")
        var changed = false
        var next = []
        for (var i = 0; i < messages.length; i++) {
            var message = messages[i]
            var applies = selectedTopic === "__all__" || message.topic === selectedTopic
            if (applies && !message.read) {
                next.push(Object.assign({}, message, { read: true }))
                changed = true
            } else {
                next.push(message)
            }
        }
        if (changed) {
            messages = next
            persistArchive()
            publishRuntime()
        }
        return changed
    }

    function dismiss(uid) {
        var wanted = String(uid || "")
        if (wanted === "")
            return false
        var next = messages.filter(function(message) {
            return message.uid !== wanted
        })
        if (next.length === messages.length)
            return false
        messages = next
        if (dismissedUids.indexOf(wanted) === -1)
            dismissedUids = dismissedUids.concat([wanted])
        persistArchive()
        publishRuntime()
        return true
    }

    function dismissRead(topic) {
        var selectedTopic = String(topic || "__all__")
        var removed = []
        var kept = []
        for (var i = 0; i < messages.length; i++) {
            var message = messages[i]
            var applies = selectedTopic === "__all__" || message.topic === selectedTopic
            if (applies && message.read)
                removed.push(message.uid)
            else
                kept.push(message)
        }
        if (removed.length === 0)
            return 0
        messages = kept
        var tombstones = dismissedUids.slice()
        for (var j = 0; j < removed.length; j++) {
            if (tombstones.indexOf(removed[j]) === -1)
                tombstones.push(removed[j])
        }
        dismissedUids = tombstones
        persistArchive()
        publishRuntime()
        return removed.length
    }

    function clearHistory() {
        var tombstones = dismissedUids.slice()
        for (var i = 0; i < messages.length; i++) {
            if (tombstones.indexOf(messages[i].uid) === -1)
                tombstones.push(messages[i].uid)
        }
        dismissedUids = tombstones
        messages = []
        persistArchive()
        publishRuntime()
    }

    IpcHandler {
        target: "ntfy"

        function refresh(): string {
            if (!root.configured)
                return "ERROR: configure a server and at least one topic"
            root.fetchMessages()
            return "REFRESH_REQUESTED"
        }

        function markRead(uid: string): string {
            return root.setRead(uid, true) ? "MARKED_READ" : "NOT_FOUND_OR_UNCHANGED"
        }

        function markUnread(uid: string): string {
            return root.setRead(uid, false) ? "MARKED_UNREAD" : "NOT_FOUND_OR_UNCHANGED"
        }

        function markReadMany(uids: string): string {
            return "MARKED_READ=" + root.setReadMany(uids, true)
        }

        function markUnreadMany(uids: string): string {
            return "MARKED_UNREAD=" + root.setReadMany(uids, false)
        }

        function dismissMany(uids: string): string {
            return "DISMISSED=" + root.dismissMany(uids)
        }

        function markAllRead(topic: string): string {
            return root.markAllRead(topic) ? "MARKED_ALL_READ" : "NOTHING_TO_CHANGE"
        }

        function dismiss(uid: string): string {
            return root.dismiss(uid) ? "DISMISSED" : "NOT_FOUND"
        }

        function dismissRead(topic: string): string {
            return "DISMISSED_READ=" + root.dismissRead(topic)
        }

        function clearHistory(): string {
            root.clearHistory()
            return "HISTORY_CLEARED"
        }

        function status(): string {
            return "configured=" + root.configured
                   + " instances=" + root.instances.length
                   + " loading=" + root.isLoading
                   + " messages=" + root.messages.length
                   + " unread=" + Ntfy.unreadCount(root.messages, "__all__")
                   + (root.errorMessage !== "" ? " error=" + root.errorMessage : "")
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalMs
        running: root.stateLoaded && root.configured
        repeat: true
        onTriggered: root.fetchMessages()
    }

    Timer {
        id: configurationRefreshTimer
        interval: 350
        repeat: false
        onTriggered: root.fetchMessages()
    }

    Component.onCompleted: {
        loadArchive()
        Qt.callLater(fetchMessages)
    }

    onContextKeyChanged: {
        if (!stateLoaded)
            return
        // Keep only cursors whose instance configuration is unchanged; new or
        // edited instances start from a full sync.
        var valid = {}
        for (var i = 0; i < instances.length; i++) {
            var instance = instances[i]
            var entry = cursors ? cursors[instance.id] : null
            if (entry && String(entry.context || "") === _instanceContext(instance))
                valid[instance.id] = entry
        }
        cursors = valid
        publishRuntime()
        configurationRefreshTimer.restart()
    }

    onSecretsStampChanged: {
        if (stateLoaded)
            configurationRefreshTimer.restart()
    }

    onConfiguredChanged: publishRuntime()
}
