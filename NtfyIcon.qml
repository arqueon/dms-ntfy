// Official ntfy outline icon, tinted to the active DMS theme.

import QtQuick
import QtQuick.Effects
import qs.Common

Item {
    id: root

    property int size: 20
    property real opticalScale: 1.0
    property color iconColor: Theme.surfaceText
    property real iconOpacity: 0.9

    width: size
    height: size

    Image {
        width: Math.round(root.size * root.opticalScale)
        height: width
        anchors.centerIn: parent
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
            // The upstream SVG is authored in #777. Normalize it to white
            // before tinting so Theme.surfaceText lands at the same luminance
            // as DMS's monochrome icons.
            brightness: 1
        }
    }
}
