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

    // Settings (PluginComponent.pluginData is reactive).
    property string baseUrl: Ntfy.normalizeBaseUrl(pluginData.baseUrl || "https://ntfy.sh")
    property string rawTopics: String(pluginData.topics || "")
    property var configuredTopics: Ntfy.parseTopics(rawTopics)
    property string topicsKey: configuredTopics.join(",")
    property string authMethod: String(pluginData.authMethod || "none")
    property string username: String(pluginData.username || "").trim()
    property int pollIntervalMs: Math.max(15, parseInt(pluginData.pollInterval) || 60) * 1000
    property int historyLimit: Math.max(0, parseInt(pluginData.historyLimit) || 0)
    property string secretsStamp: String(pluginData.secretsStamp || "")

    readonly property string contextKey: baseUrl + "|" + topicsKey
    readonly property bool configured: baseUrl !== ""
                                       && configuredTopics.length > 0
                                       && (authMethod !== "basic" || username !== "")

    // Persistent archive state.
    property var messages: []
    property var dismissedUids: []
    property string cursor: ""
    property string cursorContext: ""
    property double lastUpdated: 0

    // Runtime state shared with every widget surface.
    property bool stateLoaded: false
    property bool isLoading: false
    property string errorMessage: ""
    property int requestSequence: 0

    readonly property string authenticatedCurlScript:
        "set -eu\n" +
        "mode=$1\n" +
        "user=$2\n" +
        "url=$3\n" +
        "case \"$mode\" in\n" +
        "  token)\n" +
        "    secret=$(secret-tool lookup service dms-ntfy key token 2>/dev/null || true)\n" +
        "    [ -n \"$secret\" ] || exit 67\n" +
        "    printf 'Authorization: Bearer %s\\n' \"$secret\" | " +
        "curl -sS --max-time 25 -w '\\n%{http_code}' -H @- \"$url\"\n" +
        "    ;;\n" +
        "  basic)\n" +
        "    secret=$(secret-tool lookup service dms-ntfy key password 2>/dev/null || true)\n" +
        "    [ -n \"$secret\" ] || exit 67\n" +
        "    encoded=$(printf '%s:%s' \"$user\" \"$secret\" | base64 -w 0)\n" +
        "    printf 'Authorization: Basic %s\\n' \"$encoded\" | " +
        "curl -sS --max-time 25 -w '\\n%{http_code}' -H @- \"$url\"\n" +
        "    ;;\n" +
        "  *)\n" +
        "    curl -sS --max-time 25 -w '\\n%{http_code}' \"$url\"\n" +
        "    ;;\n" +
        "esac"

    function _archiveObject() {
        return {
            version: 1,
            messages: messages,
            dismissedUids: dismissedUids,
            cursor: cursor,
            cursorContext: cursorContext,
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
        pluginService.setGlobalVar(pluginId, "loading", isLoading)
        pluginService.setGlobalVar(pluginId, "errorMessage", errorMessage)
        pluginService.setGlobalVar(pluginId, "lastUpdated", lastUpdated)
    }

    function loadArchive() {
        var saved = pluginService
                    ? pluginService.loadPluginState(pluginId, "archive", {})
                    : {}
        messages = saved ? Ntfy.toArray(saved.messages) : []
        dismissedUids = saved ? Ntfy.toArray(saved.dismissedUids) : []
        cursor = saved ? String(saved.cursor || "") : ""
        cursorContext = saved ? String(saved.cursorContext || "") : ""
        lastUpdated = saved ? parseInt(saved.lastUpdated) || 0 : 0
        if (cursorContext !== contextKey)
            cursor = ""
        cursorContext = contextKey
        stateLoaded = true
        publishRuntime()
    }

    function _curlArguments(url) {
        if (authMethod === "none") {
            return [
                "curl", "-sS", "--max-time", "25",
                "-w", "\n%{http_code}", url
            ]
        }
        return [
            "sh", "-c", authenticatedCurlScript, "dms-ntfy",
            authMethod, username, url
        ]
    }

    function fetchMessages() {
        if (!stateLoaded || !configured || isLoading)
            return
        isLoading = true
        errorMessage = ""
        publishRuntime()
        _requestMessages(cursor !== "" ? cursor : "all", true)
    }

    function _requestMessages(since, allowFallback) {
        var url = Ntfy.subscriptionUrl(baseUrl, configuredTopics, since)
        if (url === "") {
            isLoading = false
            errorMessage = "Configure a valid ntfy URL and at least one topic"
            publishRuntime()
            return
        }
        Proc.runCommand(
            "ntfy.fetch." + (++requestSequence),
            _curlArguments(url),
            (stdout, exitCode) => {
                var response = Ntfy.parseCurl(stdout, exitCode)
                if (allowFallback && since !== "all" && response.status === 400) {
                    cursor = ""
                    _requestMessages("all", false)
                    return
                }

                isLoading = false
                if (response.status !== 200) {
                    errorMessage = Ntfy.errorText(response)
                    publishRuntime()
                    return
                }

                var incoming = Ntfy.parseNdjson(response.body, baseUrl)
                var merged = Ntfy.mergeMessages(
                    messages,
                    incoming,
                    dismissedUids,
                    historyLimit
                )
                messages = merged.messages
                cursor = Ntfy.newestMessageId(incoming, cursor)
                cursorContext = contextKey
                lastUpdated = Date.now()
                errorMessage = ""
                persistArchive()
                publishRuntime()
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
        cursor = ""
        cursorContext = contextKey
        publishRuntime()
        configurationRefreshTimer.restart()
    }

    onAuthMethodChanged: {
        if (stateLoaded)
            configurationRefreshTimer.restart()
    }

    onUsernameChanged: {
        if (stateLoaded && authMethod === "basic")
            configurationRefreshTimer.restart()
    }

    onSecretsStampChanged: {
        if (stateLoaded)
            configurationRefreshTimer.restart()
    }

    onConfiguredChanged: publishRuntime()
}
