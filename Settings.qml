// Settings.qml — public configuration in plugin_settings.json; passwords and
// tokens are stored in the system keyring under service=dms-ntfy.

import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "ntfy"

    property bool tokenStored: false
    property bool passwordStored: false

    // "", "saving", "ok" or "error" — drives the inline feedback line under each field.
    property string tokenSaveStatus: ""
    property string passwordSaveStatus: ""

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

    Timer {
        id: tokenStatusClear
        interval: 4000
        onTriggered: root.tokenSaveStatus = ""
    }

    Timer {
        id: passwordStatusClear
        interval: 4000
        onTriggered: root.passwordSaveStatus = ""
    }

    function checkSecret(key, callback) {
        Proc.runCommand(
            "ntfy.settings.check." + key,
            [
                "sh", "-c",
                "secret-tool lookup service dms-ntfy key \"$1\" >/dev/null",
                "dms-ntfy", key
            ],
            (stdout, exitCode) => {
                callback(exitCode === 0)
            }
        )
    }

    function storeSecret(key, value, callback) {
        var trimmed = String(value || "").trim()
        if (trimmed === "" || secretStoreProcess.running) {
            callback(false)
            return
        }
        secretStoreProcess.pendingKey = key
        secretStoreProcess.pendingSecret = trimmed
        secretStoreProcess.pendingCallback = callback
        secretStoreProcess.stdinEnabled = true
        secretStoreProcess.running = true
    }

    Process {
        id: secretStoreProcess

        property string pendingKey: ""
        property string pendingSecret: ""
        property var pendingCallback: null

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
            var callback = pendingCallback
            var ok = exitCode === 0
            pendingKey = ""
            pendingSecret = ""
            pendingCallback = null
            if (ok)
                root.saveValue("secretsStamp", String(Date.now()))
            if (callback)
                callback(ok)
        }
    }

    Component.onCompleted: {
        checkSecret("token", ok => tokenStored = ok)
        checkSecret("password", ok => passwordStored = ok)
    }

    StyledText {
        width: parent.width
        text: "ntfy server"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "The plugin keeps its own local review archive. Messages remain after the ntfy server cache expires and disappear only when you explicitly dismiss them."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "baseUrl"
        label: "Instance URL"
        description: "Root URL of ntfy.sh or any self-hosted ntfy instance"
        placeholder: "https://ntfy.example.org"
        defaultValue: "https://ntfy.sh"
    }

    StringSetting {
        settingKey: "topics"
        label: "Topics"
        description: "Comma-separated topic names. Each topic gets its own section beside All."
        placeholder: "alerts,backups,system"
        defaultValue: ""
    }

    StyledText {
        width: parent.width
        text: "Authentication"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    SelectionSetting {
        id: authSetting
        settingKey: "authMethod"
        label: "Authentication method"
        description: "Use public access, an ntfy access token, or username and password"
        options: [
            { label: "None / public topics", value: "none" },
            { label: "Access token", value: "token" },
            { label: "Username and password", value: "basic" }
        ]
        defaultValue: "none"
    }

    StringSetting {
        visible: authSetting.value === "basic"
        settingKey: "username"
        label: "Username"
        description: "The password is stored separately in the system keyring"
        placeholder: "user"
        defaultValue: ""
    }

    StyledText {
        visible: authSetting.value !== "none"
        width: parent.width
        text: "Secrets are stored by secret-tool in the system keyring (service “dms-ntfy”), never in plugin_settings.json."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Column {
        visible: authSetting.value === "token"
        width: parent.width
        spacing: Theme.spacingXS

        StyledText {
            text: "Access token" + (root.tokenStored ? "   ✓ stored in keyring" : "")
            font.pixelSize: Theme.fontSizeMedium
            color: root.tokenStored ? Theme.primary : Theme.surfaceText
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            DankTextField {
                id: tokenField
                width: parent.width - 100 - Theme.spacingS
                height: 36
                echoMode: TextInput.Password
                placeholderText: "tk_…"
            }

            Rectangle {
                width: 100
                height: 36
                radius: Theme.cornerRadius
                color: tokenSaveArea.containsMouse
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
                    id: tokenSaveArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        tokenStatusClear.stop()
                        root.tokenSaveStatus = "saving"
                        root.storeSecret("token", tokenField.text, ok => {
                            root.tokenSaveStatus = ok ? "ok" : "error"
                            tokenStatusClear.restart()
                            if (ok) {
                                root.tokenStored = true
                                tokenField.text = ""
                            }
                        })
                    }
                }
            }
        }

        StyledText {
            visible: root.tokenSaveStatus !== ""
            width: parent.width
            text: root.secretStatusText(root.tokenSaveStatus)
            font.pixelSize: Theme.fontSizeSmall
            color: root.secretStatusColor(root.tokenSaveStatus)
            wrapMode: Text.WordWrap
        }
    }

    Column {
        visible: authSetting.value === "basic"
        width: parent.width
        spacing: Theme.spacingXS

        StyledText {
            text: "Password" + (root.passwordStored ? "   ✓ stored in keyring" : "")
            font.pixelSize: Theme.fontSizeMedium
            color: root.passwordStored ? Theme.primary : Theme.surfaceText
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            DankTextField {
                id: passwordField
                width: parent.width - 100 - Theme.spacingS
                height: 36
                echoMode: TextInput.Password
                placeholderText: "ntfy account password"
            }

            Rectangle {
                width: 100
                height: 36
                radius: Theme.cornerRadius
                color: passwordSaveArea.containsMouse
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
                    id: passwordSaveArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        passwordStatusClear.stop()
                        root.passwordSaveStatus = "saving"
                        root.storeSecret("password", passwordField.text, ok => {
                            root.passwordSaveStatus = ok ? "ok" : "error"
                            passwordStatusClear.restart()
                            if (ok) {
                                root.passwordStored = true
                                passwordField.text = ""
                            }
                        })
                    }
                }
            }
        }

        StyledText {
            visible: root.passwordSaveStatus !== ""
            width: parent.width
            text: root.secretStatusText(root.passwordSaveStatus)
            font.pixelSize: Theme.fontSizeSmall
            color: root.secretStatusColor(root.passwordSaveStatus)
            wrapMode: Text.WordWrap
        }
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
        description: "How often the daemon checks all configured topics"
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
