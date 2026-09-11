import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    moduleName: "io.github.adamya-gupta.virtual-display"

    // BarWidget.qml owns the panel lifecycle.
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null

    // ─────────────────────────────────────────
    // State
    // ─────────────────────────────────────────

    property string activeResolution: ""
    property string displaySide: "right"

    property string customResolution: ""
    property string customResolutionError: ""

    readonly property bool displayActive:
        activeResolution !== ""

    readonly property string scriptPath:
        Quickshell.env("HOME")
        + "/.config/omarchy/plugins/io.github.adamya-gupta.virtual-display/vdcreate.sh"

    readonly property var resolutions: [
        "1280x720",
        "1366x768",
        "1600x900",
        "1920x1080",
        "2560x1440",
        "3840x2160"
    ]

    // ─────────────────────────────────────────
    // Open / close
    // ─────────────────────────────────────────

    function open() {
        root.controller.show()
        refreshStatus()
    }

    function close() {
        root.controller.hide()
    }

    // ─────────────────────────────────────────
    // Panel switching
    // ─────────────────────────────────────────

    function switchPanel(direction) {
        if (root.bar &&
            typeof root.bar.switchPanelFrom === "function") {

            return root.bar.switchPanelFrom(
                root.hostWidget || root,
                direction
            )
        }

        return false
    }

    // ─────────────────────────────────────────
    // Virtual display actions
    // ─────────────────────────────────────────

    function startResolution(resolution) {
        activeResolution = resolution
        customResolutionError = ""

        actionProcess.command = [
            "bash",
            root.scriptPath,
            "start",
            resolution,
            displaySide
        ]

        if (!actionProcess.running)
            actionProcess.running = true
    }

    function stopDisplay() {
        actionProcess.command = [
            "bash",
            root.scriptPath,
            "stop"
        ]

        activeResolution = ""
        customResolutionError = ""

        if (!actionProcess.running)
            actionProcess.running = true
    }

    function setSide(side) {
        if (side !== "left" && side !== "right")
            return

        displaySide = side

        // Move an already-running display immediately.
        if (displayActive && activeResolution !== "") {
            startResolution(activeResolution)
            return
        }

        // Otherwise save the preference.
        actionProcess.command = [
            "bash",
            root.scriptPath,
            "set-side",
            side
        ]

        if (!actionProcess.running)
            actionProcess.running = true
    }

    // ─────────────────────────────────────────
    // Custom resolution
    // ─────────────────────────────────────────

    function applyCustomResolution() {
        var value = String(
            customResolutionInput.text || ""
        ).trim()

        // Remove spaces.
        value = value.replace(/\s+/g, "")

        customResolution = value
        customResolutionError = ""

        // Must be WIDTHxHEIGHT.
        if (!/^\d+x\d+$/i.test(value)) {
            customResolutionError =
                "Use WIDTHxHEIGHT, e.g. 1920x1200"
            return
        }

        var parts = value.toLowerCase().split("x")

        var width = parseInt(parts[0], 10)
        var height = parseInt(parts[1], 10)

        if (!Number.isFinite(width) ||
            !Number.isFinite(height)) {

            customResolutionError =
                "Invalid resolution"
            return
        }

        // Reasonable limits.
        if (width < 320 ||
            height < 200) {

            customResolutionError =
                "Minimum size is 320x200"
            return
        }

        if (width > 7680 ||
            height > 4320) {

            customResolutionError =
                "Maximum size is 7680x4320"
            return
        }

        // Normalize to WIDTHxHEIGHT.
        value =
            width.toString()
            + "x"
            + height.toString()

        customResolution = value

        startResolution(value)
    }

    // ─────────────────────────────────────────
    // Status
    // ─────────────────────────────────────────

    function refreshStatus() {
        if (statusProcess.running)
            return

        statusProcess.running = true
    }

    // ─────────────────────────────────────────
    // Keyboard / popup
    // ─────────────────────────────────────────

    KeyboardPanel {
        id: panel

        anchorItem: root.anchorItem

        owner: root.hostWidget || root

        bar: root.bar

        open: root.opened

        focusTarget: keyCatcher

        contentWidth: panel.fittedContentWidth(
            Style.space(340)
        )

        contentHeight: panel.fittedContentHeight(
            content.implicitHeight
        )

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent

            // Important:
            // Let TextInput receive keyboard events normally.
            blocked: customResolutionInput.activeFocus

            onCloseRequested: root.close()

            onTabRequested: function(direction) {
                root.switchPanel(direction)
            }

            Column {
                id: content

                width: parent.width

                spacing: Style.space(8)

                // ─────────────────────────────
                // Header
                // ─────────────────────────────

                Item {
                    width: parent.width

                    height: Style.space(56)

                    Text {
                        id: displayIcon

                        anchors.left: parent.left

                        anchors.verticalCenter:
                            parent.verticalCenter

                        text: root.displayActive
                            ? "󰍹"
                            : "󰍺"

                        color: root.barForeground

                        font.family: root.bar
                            ? root.bar.fontFamily
                            : Style.font.family

                        font.pixelSize: Style.font.display
                    }

                    Column {
                        anchors.left: displayIcon.right

                        anchors.leftMargin:
                            Style.space(14)

                        anchors.right: parent.right

                        anchors.verticalCenter:
                            parent.verticalCenter

                        spacing: Style.space(2)

                        Text {
                            width: parent.width

                            text: "Virtual Display"

                            color: root.barForeground

                            font.family: root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.subtitle

                            font.bold: true

                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width

                            text: root.displayActive
                                ? "ACTIVE · "
                                  + root.activeResolution
                                  + " · "
                                  + root.displaySide.toUpperCase()
                                : "DISABLED · "
                                  + root.displaySide.toUpperCase()

                            color: Qt.darker(
                                root.barForeground,
                                1.5
                            )

                            font.family: root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.caption

                            font.bold: true

                            elide: Text.ElideRight
                        }
                    }
                }

                // ─────────────────────────────
                // Position
                // ─────────────────────────────

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width

                    text: "POSITION"

                    color: root.barForeground

                    opacity: 0.65

                    font.family: root.bar
                        ? root.bar.fontFamily
                        : Style.font.family

                    font.pixelSize: Style.font.caption

                    font.bold: true

                    font.letterSpacing: 1.0
                }

                Row {
                    width: parent.width

                    spacing: Style.space(8)

                    Repeater {
                        model: [
                            {
                                side: "left",
                                label: "󰁍  LEFT"
                            },
                            {
                                side: "right",
                                label: "RIGHT 󰁔"
                            }
                        ]

                        delegate: Rectangle {
                            required property var modelData

                            width: (
                                parent.width
                                - Style.space(8)
                            ) / 2

                            height: Style.space(42)

                            radius: Style.cornerRadius

                            color:
                                root.displaySide
                                    === modelData.side
                                ? Qt.rgba(
                                    root.barForeground.r,
                                    root.barForeground.g,
                                    root.barForeground.b,
                                    0.12
                                )
                                : sideMouse.containsMouse
                                  ? Qt.rgba(
                                      root.barForeground.r,
                                      root.barForeground.g,
                                      root.barForeground.b,
                                      0.06
                                  )
                                  : "transparent"

                            border.width:
                                root.displaySide
                                    === modelData.side
                                ? 1
                                : 0

                            border.color:
                                root.barForeground

                            Text {
                                anchors.centerIn:
                                    parent

                                text:
                                    modelData.label

                                color:
                                    root.barForeground

                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family

                                font.pixelSize:
                                    Style.font.body

                                font.bold:
                                    root.displaySide
                                    === modelData.side
                            }

                            MouseArea {
                                id: sideMouse

                                anchors.fill: parent

                                hoverEnabled: true

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked: {
                                    root.setSide(
                                        modelData.side
                                    )
                                }
                            }
                        }
                    }
                }

                // ─────────────────────────────
                // Preset resolutions
                // ─────────────────────────────

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width

                    text: "RESOLUTION"

                    color: root.barForeground

                    opacity: 0.65

                    font.family: root.bar
                        ? root.bar.fontFamily
                        : Style.font.family

                    font.pixelSize: Style.font.caption

                    font.bold: true

                    font.letterSpacing: 1.0
                }

                Repeater {
                    model: root.resolutions

                    delegate: Rectangle {
                        required property string modelData

                        width: parent.width

                        height: Style.space(40)

                        radius: Style.cornerRadius

                        color:
                            modelData
                                === root.activeResolution
                            ? Qt.rgba(
                                root.barForeground.r,
                                root.barForeground.g,
                                root.barForeground.b,
                                0.12
                            )
                            : resolutionMouse.containsMouse
                              ? Qt.rgba(
                                  root.barForeground.r,
                                  root.barForeground.g,
                                  root.barForeground.b,
                                  0.06
                              )
                              : "transparent"

                        Row {
                            anchors.fill: parent

                            anchors.leftMargin:
                                Style.space(10)

                            anchors.rightMargin:
                                Style.space(10)

                            spacing:
                                Style.space(10)

                            Text {
                                width: Style.space(18)

                                anchors.verticalCenter:
                                    parent.verticalCenter

                                text:
                                    modelData
                                    === root.activeResolution
                                    ? "●"
                                    : "○"

                                color:
                                    root.barForeground

                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family

                                font.pixelSize: 10

                                horizontalAlignment:
                                    Text.AlignHCenter
                            }

                            Text {
                                anchors.verticalCenter:
                                    parent.verticalCenter

                                text: modelData

                                color:
                                    root.barForeground

                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family

                                font.pixelSize:
                                    Style.font.body

                                font.bold:
                                    modelData
                                    === root.activeResolution
                            }
                        }

                        MouseArea {
                            id: resolutionMouse

                            anchors.fill: parent

                            hoverEnabled: true

                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked: {
                                root.startResolution(
                                    modelData
                                )
                            }
                        }
                    }
                }

                // ─────────────────────────────
                // Custom resolution
                // ─────────────────────────────

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width

                    text: "CUSTOM SIZE"

                    color: root.barForeground

                    opacity: 0.65

                    font.family: root.bar
                        ? root.bar.fontFamily
                        : Style.font.family

                    font.pixelSize: Style.font.caption

                    font.bold: true

                    font.letterSpacing: 1.0
                }

                Row {
                    width: parent.width

                    spacing: Style.space(8)

                    Rectangle {
                        width:
                            parent.width
                            - Style.space(92)

                        height: Style.space(42)

                        radius:
                            Style.cornerRadius

                        color: Qt.rgba(
                            root.barForeground.r,
                            root.barForeground.g,
                            root.barForeground.b,
                            0.05
                        )

                        border.width:
                            customResolutionInput.activeFocus
                            ? 1
                            : 0

                        border.color:
                            root.barForeground

                        Text {
                            visible:
                                customResolutionInput.text.length === 0
                                && !customResolutionInput.activeFocus

                            anchors.left:
                                parent.left

                            anchors.leftMargin:
                                Style.space(10)

                            anchors.verticalCenter:
                                parent.verticalCenter

                            text: "1920x1200"

                            color:
                                root.barForeground

                            opacity: 0.4

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.body
                        }

                        TextInput {
                            id: customResolutionInput

                            anchors.fill: parent

                            anchors.leftMargin:
                                Style.space(10)

                            anchors.rightMargin:
                                Style.space(10)

                            verticalAlignment:
                                TextInput.AlignVCenter

                            color:
                                root.barForeground

                            selectionColor:
                                Qt.rgba(
                                    root.barForeground.r,
                                    root.barForeground.g,
                                    root.barForeground.b,
                                    0.25
                                )

                            selectedTextColor:
                                root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.body

                            inputMethodHints:
                                Qt.ImhDigitsOnly

                            validator: RegularExpressionValidator {
                                regularExpression:
                                    /^\d{0,4}x?\d{0,4}$/
                            }

                            Keys.onReturnPressed: {
                                root.applyCustomResolution()
                            }

                            Keys.onEnterPressed: {
                                root.applyCustomResolution()
                            }

                            onTextChanged: {
                                root.customResolutionError = ""
                            }
                        }

                        MouseArea {
                            anchors.fill: parent

                            enabled:
                                !customResolutionInput.activeFocus

                            onClicked: {
                                customResolutionInput.forceActiveFocus()
                            }
                        }
                    }

                    Rectangle {
                        width: Style.space(84)

                        height: Style.space(42)

                        radius:
                            Style.cornerRadius

                        color:
                            applyMouse.containsMouse
                            ? Qt.rgba(
                                root.barForeground.r,
                                root.barForeground.g,
                                root.barForeground.b,
                                0.12
                            )
                            : Qt.rgba(
                                root.barForeground.r,
                                root.barForeground.g,
                                root.barForeground.b,
                                0.05
                            )

                        border.width: 1

                        border.color:
                            root.barForeground

                        Text {
                            anchors.centerIn:
                                parent

                            text: "Apply"

                            color:
                                root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.body

                            font.bold: true
                        }

                        MouseArea {
                            id: applyMouse

                            anchors.fill: parent

                            hoverEnabled: true

                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked: {
                                root.applyCustomResolution()
                            }
                        }
                    }
                }

                Text {
                    visible:
                        root.customResolutionError !== ""

                    width: parent.width

                    text:
                        root.customResolutionError

                    color: root.barForeground

                    opacity: 0.75

                    font.family:
                        root.bar
                        ? root.bar.fontFamily
                        : Style.font.family

                    font.pixelSize:
                        Style.font.caption

                    wrapMode:
                        Text.Wrap
                }

                // ─────────────────────────────
                // Disable
                // ─────────────────────────────

                PanelSeparator {
                    foreground: root.barForeground
                }

                Rectangle {
                    width: parent.width

                    height: Style.space(42)

                    radius: Style.cornerRadius

                    color:
                        disableMouse.containsMouse
                        ? Qt.rgba(
                            1,
                            0,
                            0,
                            0.08
                        )
                        : "transparent"

                    Row {
                        anchors.fill: parent

                        anchors.leftMargin:
                            Style.space(10)

                        spacing:
                            Style.space(10)

                        Text {
                            anchors.verticalCenter:
                                parent.verticalCenter

                            text: "󰅖"

                            color:
                                root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.body
                        }

                        Text {
                            anchors.verticalCenter:
                                parent.verticalCenter

                            text:
                                "Disable virtual display"

                            color:
                                root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize:
                                Style.font.body
                        }
                    }

                    MouseArea {
                        id: disableMouse

                        anchors.fill: parent

                        hoverEnabled: true

                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked: {
                            root.stopDisplay()
                        }
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────
    // Start / stop process
    // ─────────────────────────────────────────

    Process {
        id: actionProcess

        running: false

        command: []

        stderr: StdioCollector {
            id: actionError
        }

        onExited: function(exitCode) {

            if (exitCode !== 0 &&
                actionError.text.trim() !== "") {

                console.warn(
                    "VDCreate:",
                    actionError.text.trim()
                )
            }

            root.refreshStatus()
        }
    }

    // ─────────────────────────────────────────
    // Status process
    // ─────────────────────────────────────────

    Process {
        id: statusProcess

        running: false

        command: [
            "bash",
            root.scriptPath,
            "status"
        ]

        stdout: StdioCollector {
            id: statusOutput

            waitForEnd: true
        }

        onExited: function(exitCode) {

            if (exitCode !== 0) {
                root.activeResolution = ""
                return
            }

            var value = String(
                statusOutput.text || ""
            ).trim()

            if (value === "") {
                root.activeResolution = ""
                return
            }

            var parts = value.split("|")

            var resolution = parts[0]

            var side = parts.length > 1
                ? parts[1]
                : "right"

            if (side === "left" ||
                side === "right") {

                root.displaySide = side
            }

            if (resolution === "off" ||
                resolution === "") {

                root.activeResolution = ""

            } else if (resolution === "on") {

                root.activeResolution = "Unknown"

            } else {

                root.activeResolution =
                    resolution
            }
        }
    }

    // ─────────────────────────────────────────
    // Keep state synchronized
    // ─────────────────────────────────────────

    Timer {
        interval: 3000

        running: true

        repeat: true

        triggeredOnStart: true

        onTriggered: {
            root.refreshStatus()
        }
    }
}