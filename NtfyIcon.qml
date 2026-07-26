// Official ntfy outline icon, tinted to the active DMS theme.

import QtQuick
import QtQuick.Effects
import qs.Common

Item {
    id: root

    property int size: 20
    property color iconColor: Theme.surfaceText
    property real iconOpacity: 1.0

    width: size
    height: size

    Image {
        anchors.fill: parent
        source: Qt.resolvedUrl("Images/ntfy-outline.svg")
        sourceSize.width: root.width * 2
        sourceSize.height: root.height * 2
        fillMode: Image.PreserveAspectFit
        smooth: true
        antialiasing: true
        cache: false
        opacity: root.iconOpacity
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
            saturation: 0
            colorization: 1
            colorizationColor: root.iconColor
        }
    }
}
