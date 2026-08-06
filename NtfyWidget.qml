// NtfyWidget.qml — review inbox for the persistent archive maintained by
// NtfyDaemon.qml. Uses a distinct Material sensors icon in both bar orientations.

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "./JS/ntfy.js" as Ntfy

PluginComponent {
    id: root

    property var popoutService: null

    property bool hideWhenZero: pluginData.hideWhenZero === true
    readonly property bool pillHidden: hideWhenZero && configured && unreadCount === 0

    readonly property var messages: messagesGlobal.value || []
    readonly property int unreadCount: unreadGlobal.value || 0
    readonly property var availableTopics: topicsGlobal.value || []
    readonly property bool configured: configuredGlobal.value === true
    readonly property bool isLoading: loadingGlobal.value === true
    readonly property string errorMessage: String(errorGlobal.value || "")
    readonly property double lastUpdated: parseInt(updatedGlobal.value) || 0
    readonly property var configuredInstances: Ntfy.parseInstances(pluginData)
    readonly property int instanceCount: configuredInstances.length
    readonly property string instanceUrl: instanceCount > 0
                                          ? configuredInstances[0].baseUrl : ""

    property string activeTopic: "__all__"
    property string searchQuery: ""
    property string pendingSearch: ""
    property string expandedUid: ""
    property string pendingDismissUid: ""
    property bool pendingDismissRead: false
    property var selectedUids: ({})
    readonly property int selectedCount: Object.keys(selectedUids).length
    property bool batchDismissArmed: false

    onMessagesChanged: {
        if (selectedCount === 0)
            return
        var present = {}
        for (var i = 0; i < messages.length; i++)
            present[messages[i].uid] = true
        var next = {}
        var removed = false
        for (var uid in selectedUids) {
            if (present[uid])
                next[uid] = true
            else
                removed = true
        }
        if (removed) {
            selectedUids = next
            if (Object.keys(next).length === 0)
                batchDismissArmed = false
        }
    }

    readonly property var topicOptions: {
        var options = [{ value: "__all__", label: "All" }]
        for (var i = 0; i < availableTopics.length; i++)
            options.push({ value: availableTopics[i], label: availableTopics[i] })
        return options
    }

    readonly property var filteredMessages: {
        var selected = activeTopic
        var query = searchQuery
        return messages.filter(function(message) {
            var topicMatches = selected === "__all__" || message.topic === selected
            return topicMatches && Ntfy.matchesSearch(message, query)
        })
    }

    readonly property int unreadInView: {
        var count = 0
        for (var i = 0; i < filteredMessages.length; i++) {
            if (!filteredMessages[i].read)
                count++
        }
        return count
    }

    readonly property string headerDetails: {
        if (!configured)
            return "Configure a server and topics in Settings → Plugins → ntfy"
        if (errorMessage !== "")
            return errorMessage
        var detail = unreadCount + " unread · " + messages.length + " stored locally"
        if (activeTopic !== "__all__")
            detail += " · " + activeTopic
        if (searchQuery !== "")
            detail += " · " + filteredMessages.length + " matches"
        if (isLoading)
            detail += " · syncing…"
        return detail
    }

    PluginGlobalVar {
        id: messagesGlobal
        varName: "messages"
        defaultValue: []
    }

    PluginGlobalVar {
        id: unreadGlobal
        varName: "unreadCount"
        defaultValue: 0
    }

    PluginGlobalVar {
        id: topicsGlobal
        varName: "topics"
        defaultValue: []
    }

    PluginGlobalVar {
        id: configuredGlobal
        varName: "configured"
        defaultValue: false
    }

    PluginGlobalVar {
        id: loadingGlobal
        varName: "loading"
        defaultValue: false
    }

    PluginGlobalVar {
        id: errorGlobal
        varName: "errorMessage"
        defaultValue: ""
    }

    PluginGlobalVar {
        id: updatedGlobal
        varName: "lastUpdated"
        defaultValue: 0
    }

    component LinkChip: Rectangle {
        id: linkChip

        property string iconName: "open_in_new"
        property string label: ""
        property string tooltip: ""
        signal clicked()

        width: linkRow.implicitWidth + Theme.spacingS * 2
        height: 26
        radius: Theme.cornerRadius
        color: linkMouse.containsMouse
               ? Theme.withAlpha(Theme.primary, 0.25)
               : Theme.withAlpha(Theme.primary, 0.13)

        Row {
            id: linkRow
            anchors.centerIn: parent
            spacing: Theme.spacingXS

            DankIcon {
                name: linkChip.iconName
                size: 15
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: linkChip.label
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: linkMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: linkChip.clicked()
        }

    }

    function callDaemon(method, args) {
        var command = ["dms", "ipc", "call", "ntfy", method]
        var values = args || []
        for (var i = 0; i < values.length; i++)
            command.push(String(values[i]))
        Quickshell.execDetached(command)
    }

    function refresh() {
        callDaemon("refresh", [])
    }

    function markMessage(message) {
        callDaemon(message.read ? "markUnread" : "markRead", [message.uid])
    }

    function markAllVisibleRead() {
        callDaemon("markAllRead", [activeTopic])
    }

    function requestDismiss(message) {
        if (pendingDismissUid !== message.uid) {
            pendingDismissUid = message.uid
            dismissConfirmTimer.restart()
            return
        }
        dismissConfirmTimer.stop()
        pendingDismissUid = ""
        if (expandedUid === message.uid)
            expandedUid = ""
        callDaemon("dismiss", [message.uid])
    }

    function requestDismissRead() {
        if (!pendingDismissRead) {
            pendingDismissRead = true
            dismissReadConfirmTimer.restart()
            return
        }
        pendingDismissRead = false
        dismissReadConfirmTimer.stop()
        callDaemon("dismissRead", [activeTopic])
    }

    function toggleExpanded(message) {
        expandedUid = expandedUid === message.uid ? "" : message.uid
    }

    function isSelected(uid) {
        return selectedUids[uid] === true
    }

    function toggleSelect(uid) {
        var next = Object.assign({}, selectedUids)
        if (next[uid])
            delete next[uid]
        else
            next[uid] = true
        selectedUids = next
        if (selectedCount === 0)
            batchDismissArmed = false
    }

    function selectAllVisible() {
        var next = Object.assign({}, selectedUids)
        for (var i = 0; i < filteredMessages.length; i++)
            next[filteredMessages[i].uid] = true
        selectedUids = next
    }

    function clearSelection() {
        selectedUids = {}
        batchDismissArmed = false
    }

    function batchSetRead(readValue) {
        var uids = Object.keys(selectedUids)
        if (uids.length === 0)
            return
        callDaemon(readValue ? "markReadMany" : "markUnreadMany",
                   [uids.join("\n")])
        clearSelection()
    }

    function requestBatchDismiss() {
        var uids = Object.keys(selectedUids)
        if (uids.length === 0)
            return
        if (!batchDismissArmed) {
            batchDismissArmed = true
            batchDismissConfirmTimer.restart()
            return
        }
        batchDismissConfirmTimer.stop()
        batchDismissArmed = false
        callDaemon("dismissMany", [uids.join("\n")])
        clearSelection()
    }

    function openUrl(url) {
        var target = String(url || "").trim()
        if (target !== "")
            Quickshell.execDetached(["xdg-open", target])
    }

    function copyText(text) {
        Quickshell.execDetached(["dms", "cl", "copy", String(text || "")])
        ToastService?.showInfo("Notification copied")
    }

    function topicUnread(topic) {
        return Ntfy.unreadCount(messages, topic)
    }

    Timer {
        id: dismissConfirmTimer
        interval: 3500
        repeat: false
        onTriggered: root.pendingDismissUid = ""
    }

    Timer {
        id: dismissReadConfirmTimer
        interval: 3500
        repeat: false
        onTriggered: root.pendingDismissRead = false
    }

    Timer {
        id: batchDismissConfirmTimer
        interval: 3500
        repeat: false
        onTriggered: root.batchDismissArmed = false
    }

    Timer {
        id: searchDebounce
        interval: 300
        repeat: false
        onTriggered: root.searchQuery = root.pendingSearch
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: root.pillHidden ? 0 : horizontalContent.implicitWidth
            implicitHeight: horizontalContent.implicitHeight
            visible: !root.pillHidden

            Row {
                id: horizontalContent
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "sensors"
                    size: root.iconSize
                    color: {
                        if (!root.configured)
                            return Theme.surfaceVariantText
                        return Theme.primary
                    }
                    anchors.verticalCenter: parent.verticalCenter
                }

                NumericText {
                    visible: root.unreadCount > 0
                    text: Ntfy.formatCount(root.unreadCount)
                    reserveText: "99+"
                    width: reservedWidth
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.primary
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: verticalContent.implicitWidth
            implicitHeight: root.pillHidden ? 0 : verticalContent.implicitHeight
            visible: !root.pillHidden

            Column {
                id: verticalContent
                spacing: 1

                DankIcon {
                    name: "sensors"
                    size: root.iconSize
                    color: {
                        if (!root.configured)
                            return Theme.surfaceVariantText
                        return Theme.primary
                    }
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                NumericText {
                    visible: root.unreadCount > 0
                    text: Ntfy.formatCount(root.unreadCount)
                    reserveText: "99+"
                    width: reservedWidth
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.primary
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    pillRightClickAction: () => root.refresh()

    popoutWidth: 650
    popoutHeight: 620

    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Header and details are rendered as custom content below so the
            // title can act as a link to the configured ntfy instance.
            headerText: ""
            detailsText: ""
            showCloseButton: false

            Component.onCompleted: {
                if (root.configured && Date.now() - root.lastUpdated > 60000)
                    root.refresh()
            }

            // Custom header: clickable title that opens the configured ntfy
            // instance in the browser, plus a close button matching the one
            // PopoutComponent normally provides.
            Item {
                id: customHeader
                width: parent.width
                height: 40

                StyledText {
                    id: headerTitle
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: "dms-ntfy"
                    font.pixelSize: Theme.fontSizeLarge + 4
                    font.weight: Font.Bold
                    color: headerTitleMouse.containsMouse
                           ? Theme.primary
                           : Theme.surfaceText
                }

                DankIcon {
                    anchors.left: headerTitle.right
                    anchors.leftMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                    name: "open_in_new"
                    size: 16
                    color: Theme.primary
                    visible: headerTitleMouse.containsMouse
                }

                MouseArea {
                    id: headerTitleMouse
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Theme.spacingS + headerTitle.implicitWidth
                           + Theme.spacingXS + 22
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.instanceUrl !== ""
                    onClicked: root.openUrl(root.instanceUrl)
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32
                    height: 32
                    radius: 16
                    color: closeArea.containsMouse
                           ? Theme.errorHover
                           : Theme.withAlpha(Theme.errorHover, 0)

                    DankIcon {
                        anchors.centerIn: parent
                        name: "close"
                        size: Theme.iconSize - 4
                        color: closeArea.containsMouse
                               ? Theme.error
                               : Theme.surfaceText
                    }

                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: {
                            if (popout.closePopout)
                                popout.closePopout()
                        }
                    }
                }
            }

            StyledText {
                id: customDetails
                width: parent.width
                leftPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
                text: root.headerDetails
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            // Search and archive actions.
            Item {
                id: toolbar
                width: parent.width
                height: 40

                DankTextField {
                    id: searchField
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: toolbarActions.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    height: 32
                    placeholderText: "Search notifications…"
                    text: root.searchQuery
                    onTextEdited: {
                        root.pendingSearch = text
                        searchDebounce.restart()
                    }
                    onAccepted: {
                        searchDebounce.stop()
                        root.searchQuery = text
                    }
                }

                DankActionButton {
                    visible: searchField.text !== ""
                    anchors.right: toolbarActions.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "close"
                    buttonSize: 27
                    iconColor: Theme.surfaceVariantText
                    tooltipText: "Clear search"
                    onClicked: {
                        searchField.text = ""
                        searchDebounce.stop()
                        root.pendingSearch = ""
                        root.searchQuery = ""
                    }
                }

                Row {
                    id: toolbarActions
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    DankActionButton {
                        iconName: "done_all"
                        buttonSize: 30
                        iconColor: root.unreadInView > 0
                                   ? Theme.primary
                                   : Theme.surfaceVariantText
                        tooltipText: root.activeTopic === "__all__"
                                     ? "Mark all notifications as read"
                                     : "Mark this topic as read"
                        onClicked: root.markAllVisibleRead()
                    }

                    DankActionButton {
                        iconName: root.pendingDismissRead
                                  ? "delete_forever"
                                  : "delete_sweep"
                        buttonSize: 30
                        iconColor: root.pendingDismissRead
                                   ? Theme.error
                                   : Theme.surfaceVariantText
                        tooltipText: root.pendingDismissRead
                                     ? "Click again to dismiss read notifications"
                                     : "Dismiss read notifications in this view"
                        onClicked: root.requestDismissRead()
                    }

                    DankActionButton {
                        iconName: "refresh"
                        buttonSize: 30
                        iconColor: root.isLoading
                                   ? Theme.primary
                                   : Theme.surfaceVariantText
                        tooltipText: "Sync now"
                        onClicked: root.refresh()
                    }
                }
            }

            // Batch-selection bar, shown while any notification is checked.
            Item {
                id: selectionRow
                width: parent.width
                height: root.selectedCount > 0 ? 34 : 0
                visible: root.selectedCount > 0
                clip: true

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.12)

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        StyledText {
                            text: root.selectedCount + " selected"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        DankActionButton {
                            iconName: "select_all"
                            buttonSize: 26
                            iconColor: Theme.surfaceVariantText
                            tooltipText: "Select all in view"
                            onClicked: root.selectAllVisible()
                        }

                        DankActionButton {
                            iconName: "close"
                            buttonSize: 26
                            iconColor: Theme.surfaceVariantText
                            tooltipText: "Clear selection"
                            onClicked: root.clearSelection()
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        DankActionButton {
                            iconName: "done_all"
                            buttonSize: 26
                            iconColor: Theme.surfaceVariantText
                            tooltipText: "Mark selected as read"
                            onClicked: root.batchSetRead(true)
                        }

                        DankActionButton {
                            iconName: "mark_email_unread"
                            buttonSize: 26
                            iconColor: Theme.surfaceVariantText
                            tooltipText: "Mark selected as unread"
                            onClicked: root.batchSetRead(false)
                        }

                        DankActionButton {
                            iconName: root.batchDismissArmed
                                      ? "delete_forever" : "delete"
                            buttonSize: 26
                            iconColor: root.batchDismissArmed
                                       ? Theme.error : Theme.surfaceVariantText
                            tooltipText: root.batchDismissArmed
                                         ? "Click again: dismiss "
                                           + root.selectedCount + " notifications"
                                         : "Dismiss selected"
                            onClicked: root.requestBatchDismiss()
                        }
                    }
                }
            }

            Item {
                id: archiveArea
                width: parent.width
                height: Math.max(
                    180,
                    root.popoutHeight - customHeader.height
                    - customDetails.height - toolbar.height
                    - selectionRow.height - Theme.spacingXL * 2
                )

                Rectangle {
                    id: topicRail
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.spacingS
                    width: 142
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    DankListView {
                        id: topicList
                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        clip: true
                        spacing: 2
                        model: root.topicOptions

                        delegate: Rectangle {
                            id: topicRow

                            required property var modelData

                            width: topicList.width
                            height: 38
                            radius: Theme.cornerRadius
                            color: root.activeTopic === modelData.value
                                   ? Theme.withAlpha(Theme.primary, 0.20)
                                   : (topicMouse.containsMouse
                                      ? Theme.surfaceContainerHighest
                                      : "transparent")

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                NtfyIcon {
                                    visible: topicRow.modelData.value === "__all__"
                                    size: 17
                                    iconColor: root.activeTopic === topicRow.modelData.value
                                               ? Theme.primary
                                               : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                DankIcon {
                                    visible: topicRow.modelData.value !== "__all__"
                                    name: "tag"
                                    size: 17
                                    color: root.activeTopic === topicRow.modelData.value
                                           ? Theme.primary
                                           : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    width: parent.width - 45
                                           - (topicUnreadBadge.visible
                                              ? topicUnreadBadge.width
                                              : 0)
                                    text: topicRow.modelData.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: root.activeTopic === topicRow.modelData.value
                                                 ? Font.DemiBold
                                                 : Font.Normal
                                    color: root.activeTopic === topicRow.modelData.value
                                           ? Theme.primary
                                           : Theme.surfaceText
                                    elide: Text.ElideRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Rectangle {
                                    id: topicUnreadBadge
                                    property int count: root.topicUnread(
                                        topicRow.modelData.value
                                    )
                                    visible: count > 0
                                    width: Math.max(topicUnreadText.implicitWidth + 8, height)
                                    height: 18
                                    radius: height / 2
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledText {
                                        id: topicUnreadText
                                        anchors.centerIn: parent
                                        text: Ntfy.formatCount(parent.count)
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                        color: Theme.onPrimary
                                    }
                                }
                            }

                            MouseArea {
                                id: topicMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.activeTopic = topicRow.modelData.value
                                    root.expandedUid = ""
                                    root.pendingDismissUid = ""
                                    root.pendingDismissRead = false
                                    root.clearSelection()
                                }
                            }
                        }
                    }
                }

                Item {
                    id: notificationPane
                    anchors.left: topicRail.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom

                    DankListView {
                        id: notificationList
                        anchors.fill: parent
                        clip: true
                        spacing: Theme.spacingXS
                        model: root.filteredMessages

                        delegate: Rectangle {
                            id: notificationCard

                            required property var modelData
                            required property int index

                            readonly property bool expanded:
                                root.expandedUid === modelData.uid

                            width: notificationList.width
                            height: cardContent.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius
                            color: cardHover.hovered
                                   ? Theme.surfaceContainerHighest
                                   : (modelData.read
                                      ? Theme.surfaceContainerHigh
                                      : Theme.withAlpha(Theme.primary, 0.10))
                            border.width: modelData.read ? 0 : 1
                            border.color: modelData.read
                                          ? "transparent"
                                          : Theme.withAlpha(Theme.primary, 0.30)

                            HoverHandler {
                                id: cardHover
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (root.selectedCount > 0)
                                        root.toggleSelect(
                                            notificationCard.modelData.uid
                                        )
                                    else
                                        root.toggleExpanded(
                                            notificationCard.modelData
                                        )
                                }
                            }

                            Column {
                                id: cardContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingXS

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    Item {
                                        width: 20
                                        height: 34
                                        anchors.verticalCenter: parent.verticalCenter

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: root.isSelected(
                                                      notificationCard.modelData.uid
                                                  )
                                                  ? "check_box"
                                                  : "check_box_outline_blank"
                                            size: 18
                                            color: root.isSelected(
                                                       notificationCard.modelData.uid
                                                   )
                                                   ? Theme.primary
                                                   : Theme.surfaceVariantText
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleSelect(
                                                notificationCard.modelData.uid
                                            )
                                        }
                                    }

                                    Rectangle {
                                        width: 4
                                        height: 34
                                        radius: 2
                                        color: notificationCard.modelData.read
                                               ? Theme.outline
                                               : Theme.primary
                                        opacity: notificationCard.modelData.read ? 0.35 : 1
                                    }

                                    DankIcon {
                                        name: Ntfy.priorityIcon(
                                            notificationCard.modelData.priority
                                        )
                                        size: 17
                                        color: {
                                            var priority =
                                                notificationCard.modelData.priority
                                            if (priority >= 5)
                                                return Theme.error
                                            if (priority === 4)
                                                return Theme.warning
                                            return notificationCard.modelData.read
                                                   ? Theme.surfaceVariantText
                                                   : Theme.primary
                                        }
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Rectangle {
                                        width: topicLabel.implicitWidth
                                               + Theme.spacingS * 2
                                        height: 21
                                        radius: height / 2
                                        color: Theme.withAlpha(Theme.primary, 0.14)
                                        anchors.verticalCenter: parent.verticalCenter

                                        StyledText {
                                            id: topicLabel
                                            anchors.centerIn: parent
                                            text: notificationCard.modelData.topic
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.primary
                                        }
                                    }

                                    Rectangle {
                                        // Server-of-origin chip; only useful
                                        // once several servers feed the archive.
                                        visible: root.instanceCount > 1
                                                 && String(notificationCard
                                                           .modelData.source
                                                           || "") !== ""
                                        width: visible
                                               ? hostLabel.implicitWidth
                                                 + Theme.spacingS * 2
                                               : 0
                                        height: 21
                                        radius: height / 2
                                        color: Theme.withAlpha(Theme.secondary, 0.14)
                                        anchors.verticalCenter: parent.verticalCenter

                                        StyledText {
                                            id: hostLabel
                                            anchors.centerIn: parent
                                            text: Ntfy.sourceLabel(
                                                notificationCard.modelData.source)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    StyledText {
                                        width: Math.max(
                                            20,
                                            parent.width
                                            - parent.children[0].width
                                            - parent.children[1].width
                                            - parent.children[2].width
                                            - parent.children[3].width
                                            - parent.children[4].width
                                            - cardActions.width
                                            - Theme.spacingXS * 7
                                        )
                                        text: Ntfy.relativeTime(
                                            notificationCard.modelData.time
                                        )
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        horizontalAlignment: Text.AlignRight
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Row {
                                        id: cardActions
                                        spacing: 0
                                        anchors.verticalCenter: parent.verticalCenter

                                        DankActionButton {
                                            iconName: notificationCard.modelData.read
                                                      ? "mark_email_unread"
                                                      : "done"
                                            buttonSize: 27
                                            iconColor:
                                                notificationCard.modelData.read
                                                ? Theme.surfaceVariantText
                                                : Theme.primary
                                            tooltipText:
                                                notificationCard.modelData.read
                                                ? "Mark unread"
                                                : "Mark read"
                                            onClicked: root.markMessage(
                                                notificationCard.modelData
                                            )
                                        }

                                        DankActionButton {
                                            iconName:
                                                root.pendingDismissUid
                                                === notificationCard.modelData.uid
                                                ? "delete_forever"
                                                : "close"
                                            buttonSize: 27
                                            iconColor:
                                                root.pendingDismissUid
                                                === notificationCard.modelData.uid
                                                ? Theme.error
                                                : Theme.surfaceVariantText
                                            tooltipText:
                                                root.pendingDismissUid
                                                === notificationCard.modelData.uid
                                                ? "Click again to dismiss"
                                                : "Dismiss from local archive"
                                            onClicked: root.requestDismiss(
                                                notificationCard.modelData
                                            )
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    text: Ntfy.titleOf(notificationCard.modelData)
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight:
                                        notificationCard.modelData.read
                                        ? Font.Medium
                                        : Font.DemiBold
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    visible:
                                        notificationCard.modelData.message !== ""
                                    width: parent.width
                                    text: notificationCard.modelData.message
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    opacity: notificationCard.modelData.read ? 0.78 : 0.94
                                    wrapMode: Text.WordWrap
                                    maximumLineCount:
                                        notificationCard.expanded ? 16 : 3
                                    elide: Text.ElideRight
                                }

                                Column {
                                    width: parent.width
                                    visible: notificationCard.expanded
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        width: parent.width
                                        text: Ntfy.fullTime(
                                                  notificationCard.modelData.time
                                              )
                                              + " · "
                                              + Ntfy.sourceHost(
                                                  notificationCard.modelData.source
                                              )
                                              + " · "
                                              + Ntfy.priorityLabel(
                                                  notificationCard.modelData.priority
                                              )
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }

                                    Flow {
                                        width: parent.width
                                        spacing: Theme.spacingXS
                                        visible:
                                            notificationCard.modelData.tags.length > 0

                                        Repeater {
                                            model:
                                                notificationCard.modelData.tags

                                            delegate: Rectangle {
                                                required property string modelData

                                                width: tagText.implicitWidth
                                                       + Theme.spacingS * 2
                                                height: 21
                                                radius: height / 2
                                                color: Theme.surfaceContainerHighest

                                                StyledText {
                                                    id: tagText
                                                    anchors.centerIn: parent
                                                    text: parent.modelData
                                                    font.pixelSize:
                                                        Theme.fontSizeSmall
                                                    color:
                                                        Theme.surfaceVariantText
                                                }
                                            }
                                        }
                                    }

                                    Flow {
                                        width: parent.width
                                        spacing: Theme.spacingXS

                                        LinkChip {
                                            visible:
                                                notificationCard.modelData.click !== ""
                                            iconName: "open_in_new"
                                            label: "Open link"
                                            tooltip:
                                                notificationCard.modelData.click
                                            onClicked: root.openUrl(
                                                notificationCard.modelData.click
                                            )
                                        }

                                        LinkChip {
                                            visible:
                                                notificationCard.modelData.attachment
                                                && notificationCard.modelData.attachment.url
                                                   !== ""
                                            iconName: "attachment"
                                            label: {
                                                var attachment =
                                                    notificationCard.modelData.attachment
                                                if (!attachment)
                                                    return "Attachment"
                                                var size = Ntfy.formatBytes(
                                                    attachment.size
                                                )
                                                return attachment.name
                                                       + (size !== ""
                                                          ? " · " + size
                                                          : "")
                                            }
                                            tooltip:
                                                notificationCard.modelData.attachment
                                                ? notificationCard.modelData.attachment.url
                                                : ""
                                            onClicked: {
                                                if (notificationCard.modelData.attachment)
                                                    root.openUrl(
                                                        notificationCard.modelData.attachment.url
                                                    )
                                            }
                                        }

                                        Repeater {
                                            model:
                                                notificationCard.modelData.actions

                                            delegate: LinkChip {
                                                required property var modelData

                                                visible:
                                                    modelData.action === "view"
                                                    && modelData.url !== ""
                                                iconName: "ads_click"
                                                label: modelData.label
                                                tooltip: modelData.url
                                                onClicked:
                                                    root.openUrl(modelData.url)
                                            }
                                        }

                                        LinkChip {
                                            iconName: "content_copy"
                                            label: "Copy"
                                            tooltip: "Copy title and message"
                                            onClicked: root.copyText(
                                                Ntfy.titleOf(
                                                    notificationCard.modelData
                                                )
                                                + "\n"
                                                + notificationCard.modelData.message
                                            )
                                        }
                                    }

                                    StyledText {
                                        property int nonViewActions: {
                                            var count = 0
                                            var actions =
                                                notificationCard.modelData.actions
                                            for (var i = 0;
                                                 i < actions.length;
                                                 i++) {
                                                if (actions[i].action !== "view")
                                                    count++
                                            }
                                            return count
                                        }
                                        visible: nonViewActions > 0
                                        width: parent.width
                                        text: nonViewActions
                                              + " HTTP/broadcast action"
                                              + (nonViewActions === 1 ? "" : "s")
                                              + " shown for review only; this plugin never executes them."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.warning
                                        wrapMode: Text.WordWrap
                                    }

                                    StyledText {
                                        visible:
                                            root.pendingDismissUid
                                            === notificationCard.modelData.uid
                                        text:
                                            "Click × again to remove this notification from the local archive."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.error
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingXL * 2
                        spacing: Theme.spacingS
                        visible: root.filteredMessages.length === 0

                        NtfyIcon {
                            size: 52
                            iconColor: Theme.surfaceVariantText
                            iconOpacity: 0.45
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                if (!root.configured)
                                    return "Set the instance URL and topics in Settings → Plugins → ntfy"
                                if (root.isLoading && root.messages.length === 0)
                                    return "Loading cached notifications…"
                                if (root.errorMessage !== ""
                                        && root.messages.length === 0)
                                    return root.errorMessage
                                if (root.searchQuery !== "")
                                    return "No notifications match this search"
                                if (root.activeTopic !== "__all__")
                                    return "No stored notifications for "
                                           + root.activeTopic
                                return "No notifications stored yet"
                            }
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
            }
        }
    }
}
