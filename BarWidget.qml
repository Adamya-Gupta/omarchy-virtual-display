import QtQuick
import qs.Ui

BarWidget {
    id: root

    moduleName: "io.github.adamya-gupta.virtual-display"

    readonly property bool displayActive:
        panelLoader.item
            ? panelLoader.item.displayActive
            : false

    readonly property string activeResolution:
        panelLoader.item
            ? panelLoader.item.activeResolution
            : ""

    readonly property string displaySide:
    panelLoader.item
        ? panelLoader.item.displaySide
        : "right"

    readonly property bool opened:
        panelLoader.item
            ? panelLoader.item.opened
            : false

    function open() {
        if (panelLoader.item)
            panelLoader.item.open()
    }

    function close() {
        if (panelLoader.item)
            panelLoader.item.close()
    }

    function toggle() {
        if (panelLoader.item)
            panelLoader.item.toggle()
    }

    function closeForPopoutSwitch() {
        if (panelLoader.item)
            panelLoader.item.closeForPopoutSwitch()
    }

    function injectPanel() {
        if (!panelLoader.item)
            return

        panelLoader.item.bar = root.bar
        panelLoader.item.anchorItem = button
        panelLoader.item.hostWidget = root
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()

    Loader {
        id: panelLoader

        active: true

        source: Qt.resolvedUrl("Panel.qml")

        visible: false

        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    WidgetButton {
        id: button

        anchors.fill: parent

        bar: root.bar

        text: root.displayActive
            ? "󰍹 VD ON"
            : "󰍹 VD OFF"

        tooltipText: root.displayActive
            ? "Virtual Display • " + root.activeResolution  + " • "
      + root.displaySide.toUpperCase()
            : "Virtual Display • Off"

        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton)
                root.toggle()
        }
    }
}