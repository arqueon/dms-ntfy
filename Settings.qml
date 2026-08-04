// Settings.qml — public configuration in plugin_settings.json; passwords and
// tokens are stored in the system keyring under service=dms-ntfy, one entry
// per instance (key "token:<id>" / "password:<id>"). Settings written before
// multi-instance support migrate into a single instance that keeps reading
// the original un-namespaced keyring entries.

import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "./JS/ntfy.js" as Ntfy

PluginSettings {
    id: root

    pluginId: "ntfy"

    // Working copy of the instance list. Every mutation reassigns the array
    // and saves, so the daemon reacts through pluginData immediately.
    property var instances: []
    // instance id -> true when its keyring secret exists.
    property var secretStored: ({})
    // instance id -> "", "saving", "ok" or "error" for the inline feedback.
    property var secretStatus: ({})

    // The shell injects pluginService shortly after creation; loading before
    // that yields defaults, and a save in that window would overwrite the real
    // configuration with an empty list. _loaded gates both directions.
    property bool _loaded: false

    function _load() {
        if (_loaded || !pluginService)
            return
        var saved = root.loadValue("instances", null)
        var data = { instances: saved }
        if (!saved || Ntfy.toArray(saved).length === 0) {
            data = {
                baseUrl: root.loadValue("baseUrl", ""),
                topics: root.loadValue("topics", ""),
                authMethod: root.loadValue("authMethod", "none"),
                username: root.loadValue("username", "")
            }
        }
        instances = Ntfy.parseInstances(data)
        _loaded = true
        for (var i = 0; i < instances.length; i++)
            _refreshSecretIndicator(instances[i])
    }

    function _persist() {
        if (!_loaded)
            return
        root.saveValue("instances", instances)
    }

    function updateInstance(index, patch) {
        var next = instances.slice()
        if (index < 0 || index >= next.length)
            return
        next[index] = Object.assign({}, next[index], patch)
        instances = next
        _persist()
    }

    function addInstance() {
        var next = instances.slice()
        next.push({
            id: "i" + Date.now().toString(36),
            baseUrl: "",
            topics: [],
            authMethod: "none",
            username: "",
            legacySecrets: false
        })
        instances = next
        _persist()
    }

    function removeInstance(index) {
        var next = instances.slice()
        if (index < 0 || index >= next.length)
            return
        next.splice(index, 1)
        instances = next
        _persist()
    }

    function _setSecretStatus(instanceId, status) {
        var next = {}
        for (var key in secretStatus)
            next[key] = secretStatus[key]
        next[instanceId] = status
        secretStatus = next
    }

    function _setSecretStored(instanceId, stored) {
        var next = {}
        for (var key in secretStored)
            next[key] = secretStored[key]
        next[instanceId] = stored
        secretStored = next
    }

    function secretKeyOf(instance) {
        return (instance.authMethod === "token" ? "token:" : "password:")
               + instance.id
    }

    function _refreshSecretIndicator(instance) {
        if (instance.authMethod === "none")
            return
        var keys = Ntfy.secretKeys(
            instance, instance.authMethod === "token" ? "token" : "password")
        var script = keys.map(function(key) {
            return "secret-tool lookup service dms-ntfy key '" + key
                   + "' >/dev/null 2>&1"
        }).join(" || ")
        Proc.runCommand(
            "ntfy.settings.check." + instance.id,
            ["sh", "-c", script],
            (stdout, exitCode) => {
                _setSecretStored(instance.id, exitCode === 0)
            }
        )
    }

    function storeSecret(instance, value) {
        var trimmed = String(value || "").trim()
        if (trimmed === "" || secretStoreProcess.running) {
            _setSecretStatus(instance.id, "error")
            return
        }
        _setSecretStatus(instance.id, "saving")
        secretStoreProcess.pendingInstanceId = instance.id
        secretStoreProcess.pendingKey = secretKeyOf(instance)
        secretStoreProcess.pendingSecret = trimmed
        secretStoreProcess.stdinEnabled = true
        secretStoreProcess.running = true
    }

    function secretStatusText(status) {
        if (status === "saving")
            return "Saving…"
        if (status === "ok")
            return "✓ Saved to keyring"
        if (status === "error")
            return "✗ Not saved — empty value, busy, or the keyring refused it"
        return ""
    }

    function secretStatusColor(status) {
        if (status === "ok")
            return Theme.primary
        if (status === "error")
            return Theme.error
        return Theme.surfaceVariantText
    }

    Process {
        id: secretStoreProcess

        property string pendingInstanceId: ""
        property string pendingKey: ""
        property string pendingSecret: ""

        command: [
            "secret-tool", "store",
            "--label=DMS ntfy " + pendingKey,
            "service", "dms-ntfy",
            "key", pendingKey
        ]
        stdinEnabled: true
        running: false

        onStarted: {
            write(pendingSecret)
            pendingSecret = ""
            // secret-tool reads the secret until EOF; without closing stdin it
            // waits forever, the process never exits and nothing gets stored.
            stdinEnabled = false
        }

        onExited: function(exitCode) {
            var instanceId = pendingInstanceId
            var ok = exitCode === 0
            pendingInstanceId = ""
            pendingKey = ""
            pendingSecret = ""
            root._setSecretStatus(instanceId, ok ? "ok" : "error")
            if (ok) {
                root._setSecretStored(instanceId, true)
                root.saveValue("secretsStamp", String(Date.now()))
            }
        }
    }

    Component.onCompleted: Qt.callLater(_load)

    onPluginServiceChanged: _load()

    StyledText {
        width: parent.width
        text: "ntfy servers"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "The plugin polls every configured server and merges all messages into one archive. Messages remain after the server cache expires and disappear only when you explicitly dismiss them."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Repeater {
        model: root.instances

        delegate: Rectangle {
            id: instanceCard

            required property var modelData
            required property int index

            width: parent.width
            implicitHeight: cardColumn.implicitHeight + Theme.spacingL * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Column {
                id: cardColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width - 90 - Theme.spacingS
                        text: instanceCard.modelData.baseUrl !== ""
                              ? Ntfy.sourceHost(instanceCard.modelData.baseUrl)
                              : "New server"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        width: 90
                        height: 28
                        radius: Theme.cornerRadius
                        color: removeArea.containsMouse
                               ? Theme.withAlpha(Theme.error, 0.35)
                               : Theme.withAlpha(Theme.error, 0.18)

                        StyledText {
                            anchors.centerIn: parent
                            text: "Remove"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.error
                        }

                        MouseArea {
                            id: removeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeInstance(instanceCard.index)
                        }
                    }
                }

                StyledText {
                    text: "Server URL"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                DankTextField {
                    width: parent.width
                    height: 36
                    text: instanceCard.modelData.baseUrl
                    placeholderText: "https://ntfy.example.org"
                    onEditingFinished: root.updateInstance(
                        instanceCard.index,
                        { baseUrl: Ntfy.normalizeBaseUrl(text) })
                }

                StyledText {
                    text: "Topics (comma-separated)"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                DankTextField {
                    width: parent.width
                    height: 36
                    text: Ntfy.toArray(instanceCard.modelData.topics).join(",")
                    placeholderText: "alerts,backups,system"
                    onEditingFinished: root.updateInstance(
                        instanceCard.index,
                        { topics: Ntfy.parseTopics(text) })
                }

                StyledText {
                    text: "Authentication"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Row {
                    spacing: Theme.spacingS

                    Repeater {
                        model: [
                            { label: "Public", value: "none" },
                            { label: "Token", value: "token" },
                            { label: "User + password", value: "basic" }
                        ]

                        delegate: Rectangle {
                            required property var modelData

                            readonly property bool selected:
                                instanceCard.modelData.authMethod === modelData.value

                            width: chipLabel.implicitWidth + Theme.spacingM * 2
                            height: 30
                            radius: Theme.cornerRadius
                            color: selected
                                   ? Theme.withAlpha(Theme.primary, 0.3)
                                   : chipArea.containsMouse
                                     ? Theme.withAlpha(Theme.primary, 0.15)
                                     : Theme.surfaceContainer

                            StyledText {
                                id: chipLabel
                                anchors.centerIn: parent
                                text: parent.modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: parent.selected
                                       ? Theme.primary
                                       : Theme.surfaceText
                            }

                            MouseArea {
                                id: chipArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.updateInstance(
                                        instanceCard.index,
                                        { authMethod: parent.modelData.value })
                                    root._refreshSecretIndicator(
                                        root.instances[instanceCard.index])
                                }
                            }
                        }
                    }
                }

                DankTextField {
                    visible: instanceCard.modelData.authMethod === "basic"
                    width: parent.width
                    height: 36
                    text: instanceCard.modelData.username
                    placeholderText: "username"
                    onEditingFinished: root.updateInstance(
                        instanceCard.index,
                        { username: text.trim() })
                }

                Column {
                    visible: instanceCard.modelData.authMethod !== "none"
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledText {
                        text: (instanceCard.modelData.authMethod === "token"
                               ? "Access token" : "Password")
                              + (root.secretStored[instanceCard.modelData.id] === true
                                 ? "   ✓ stored in keyring" : "")
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.secretStored[instanceCard.modelData.id] === true
                               ? Theme.primary
                               : Theme.surfaceText
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        DankTextField {
                            id: secretField
                            width: parent.width - 100 - Theme.spacingS
                            height: 36
                            echoMode: TextInput.Password
                            placeholderText:
                                instanceCard.modelData.authMethod === "token"
                                ? "tk_…" : "account password"
                        }

                        Rectangle {
                            width: 100
                            height: 36
                            radius: Theme.cornerRadius
                            color: secretSaveArea.containsMouse
                                   ? Theme.withAlpha(Theme.primary, 0.35)
                                   : Theme.withAlpha(Theme.primary, 0.22)

                            StyledText {
                                anchors.centerIn: parent
                                text: "Save"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.primary
                            }

                            MouseArea {
                                id: secretSaveArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.storeSecret(
                                        instanceCard.modelData, secretField.text)
                                    secretField.text = ""
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: (root.secretStatus[instanceCard.modelData.id] || "") !== ""
                        width: parent.width
                        text: root.secretStatusText(
                            root.secretStatus[instanceCard.modelData.id] || "")
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.secretStatusColor(
                            root.secretStatus[instanceCard.modelData.id] || "")
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 40
        radius: Theme.cornerRadius
        color: addArea.containsMouse
               ? Theme.withAlpha(Theme.primary, 0.3)
               : Theme.withAlpha(Theme.primary, 0.18)

        StyledText {
            anchors.centerIn: parent
            text: "Add server"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.primary
        }

        MouseArea {
            id: addArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addInstance()
        }
    }

    StyledText {
        width: parent.width
        text: "Secrets are stored by secret-tool in the system keyring (service “dms-ntfy”, one entry per server), never in plugin_settings.json."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: "Behavior"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    SelectionSetting {
        settingKey: "pollInterval"
        label: "Poll interval"
        description: "How often the daemon checks every configured server"
        options: [
            { label: "30 seconds", value: "30" },
            { label: "1 minute", value: "60" },
            { label: "5 minutes", value: "300" },
            { label: "15 minutes", value: "900" }
        ]
        defaultValue: "60"
    }

    SelectionSetting {
        settingKey: "historyLimit"
        label: "Local history limit"
        description: "Unlimited keeps every message until you dismiss it. A limit drops the oldest messages after a successful sync."
        options: [
            { label: "Unlimited", value: "0" },
            { label: "250 messages", value: "250" },
            { label: "500 messages", value: "500" },
            { label: "1,000 messages", value: "1000" },
            { label: "2,500 messages", value: "2500" }
        ]
        defaultValue: "0"
    }

    ToggleSetting {
        settingKey: "hideWhenZero"
        label: "Hide when nothing is unread"
        description: "Collapse the DankBar pill while the unread count is zero"
        defaultValue: false
    }

    StyledText {
        width: parent.width
        text: "This archive does not create additional DMS desktop notifications, avoiding duplicates with ntfy clients already integrated into the notification center."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        topPadding: Theme.spacingS
    }
}
