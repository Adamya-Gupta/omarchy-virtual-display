pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    moduleName: "io.github.adamya-gupta.virtual-display"

    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null

    // ─────────────────────────────────────────
    // Display state
    // ─────────────────────────────────────────

    property string activeResolution: ""
    property string displaySide: "right"

    readonly property bool displayActive:
        activeResolution !== ""

    // ─────────────────────────────────────────
    // Custom resolution
    // ─────────────────────────────────────────

    property string customResolution: ""
    property string customResolutionError: ""

    // ─────────────────────────────────────────
    // VNC state
    //
    // local:
    //   127.0.0.1:5900
    //   remote access through SSH tunnel
    //
    // network:
    //   0.0.0.0:5900
    //   password + TLS
    // ─────────────────────────────────────────

    property string vncMode: "local"

    property string vncBindAddress: "127.0.0.1:5900"
    property string vncConnectHost: "127.0.0.1"
    property string vncUsername: ""
    property string vncPassword: ""
    property string sshCommand: ""
    property string networkAddressesCsv: ""
    property bool vncPasswordVisible: false

    readonly property bool networkAccess:
        vncMode === "network"

    readonly property string effectiveBindAddress:
        networkAccess
        ? "0.0.0.0:5900"
        : "127.0.0.1:5900"

    readonly property string effectiveConnectHost:
        networkAccess
        ? (vncConnectHost !== "" ? vncConnectHost : "Detecting...")
        : "127.0.0.1"

    readonly property string effectiveUsername:
        networkAccess
        ? (vncUsername !== "" ? vncUsername : "virtual-display")
        : ""

    readonly property string effectiveSshCommand:
        sshCommand !== ""
        ? sshCommand
        : "ssh -L 5900:127.0.0.1:5900 "
          + (Quickshell.env("USER") || "<user>")
          + "@"
          + (vncConnectHost !== "" ? vncConnectHost : "<omarchy-ip>")

    function networkConnectionsText() {
        if (networkAddressesCsv === "")
            return "No active IPv4 network address detected."

        var addresses = networkAddressesCsv.split(",")
        var lines = []

        for (var i = 0; i < addresses.length; i++) {
            var address = String(addresses[i]).trim()

            if (address !== "") {
                lines.push("• " + address + ":5900")
            }
        }

        return lines.length > 0
            ? lines.join("\n")
            : "No active IPv4 network address detected."
    }

    // Only actual state-changing commands block controls.
    // Background status polling must never disable clicks.
    readonly property bool busy:
        actionProcess.running

    // ─────────────────────────────────────────
    // Action bookkeeping
    // ─────────────────────────────────────────

    property string actionRequestedResolution: ""
    property bool actionCommandWasStart: false
    property bool actionCommandWasStop: false
    property bool pendingStatusRefresh: false

    // Prevent a status request that began before a state-changing action
    // from overwriting the newer UI state with stale data.
    property int stateGeneration: 0
    property int statusRequestGeneration: -1

    // Hyprland may take a short moment to expose a newly-created headless
    // monitor to `hyprctl monitors`. Keep a successful start visible while
    // we retry the status query.
    property bool waitingForActiveStatus: false
    property int activeStatusMisses: 0

    // ─────────────────────────────────────────
    // Script
    // ─────────────────────────────────────────

    readonly property string scriptPath:
        Quickshell.env("HOME")
        + "/.config/omarchy/plugins/io.github.adamya-gupta.virtual-display/vdcreate.sh"

    // ─────────────────────────────────────────
    // Presets
    // ─────────────────────────────────────────

    readonly property var resolutions: [
        "1280x720",
        "1366x768",
        "1600x900",
        "1920x1080",
        "2560x1440",
        "3840x2160"
    ]

    // ─────────────────────────────────────────
    // Panel lifecycle
    // ─────────────────────────────────────────

    function open() {
        root.controller.show()
        requestStatusRefresh(0)
    }

    function close() {
        root.controller.hide()
    }

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
    // Status helpers
    // ─────────────────────────────────────────

    function requestStatusRefresh(delayMs) {
        pendingStatusRefresh = true
        statusRetryTimer.interval = delayMs > 0 ? delayMs : 1
        statusRetryTimer.restart()
    }

    function refreshStatus() {
        if (actionProcess.running) {
            pendingStatusRefresh = true
            return
        }

        if (statusProcess.running) {
            pendingStatusRefresh = true
            return
        }

        pendingStatusRefresh = false
        statusRequestGeneration = stateGeneration

        statusProcess.command = [
            "bash",
            root.scriptPath,
            "status"
        ]

        statusProcess.running = true
    }

    // ─────────────────────────────────────────
    // Start / recreate
    // ─────────────────────────────────────────

    function startResolution(resolution) {
        if (resolution === "" || actionProcess.running)
            return

        customResolutionError = ""
        vncPasswordVisible = false

        actionRequestedResolution = resolution
        actionCommandWasStart = true
        actionCommandWasStop = false
        stateGeneration++

        actionProcess.command = [
            "bash",
            root.scriptPath,
            "start",
            resolution,
            displaySide,
            vncMode
        ]

        actionProcess.running = true
    }

    // ─────────────────────────────────────────
    // Stop
    // ─────────────────────────────────────────

    function stopDisplay() {
        if (actionProcess.running)
            return

        customResolutionError = ""
        vncPasswordVisible = false

        actionRequestedResolution = ""
        actionCommandWasStart = false
        actionCommandWasStop = true
        stateGeneration++

        actionProcess.command = [
            "bash",
            root.scriptPath,
            "stop"
        ]

        actionProcess.running = true
    }

    // ─────────────────────────────────────────
    // Position
    // ─────────────────────────────────────────

    function setSide(side) {
        if (side !== "left" && side !== "right")
            return

        if (actionProcess.running)
            return

        displaySide = side
        vncPasswordVisible = false

        if (displayActive && activeResolution !== "") {
            actionRequestedResolution = activeResolution
            actionCommandWasStart = true
            actionCommandWasStop = false
            stateGeneration++

            actionProcess.command = [
                "bash",
                root.scriptPath,
                "start",
                activeResolution,
                side,
                vncMode
            ]

            actionProcess.running = true
            return
        }

        actionCommandWasStart = false
        actionCommandWasStop = false
        stateGeneration++

        actionProcess.command = [
            "bash",
            root.scriptPath,
            "set-side",
            side
        ]

        actionProcess.running = true
    }

    // ─────────────────────────────────────────
    // VNC mode
    // ─────────────────────────────────────────

    function setVncMode(mode) {
        if (mode !== "local" && mode !== "network")
            return

        if (actionProcess.running)
            return

        vncMode = mode
        vncPasswordVisible = false

        // Keep immediately visible UI state consistent with mode.
        if (mode === "network") {
            vncBindAddress = "0.0.0.0:5900"
            vncConnectHost = ""
            vncUsername = "virtual-display"
        } else {
            vncBindAddress = "127.0.0.1:5900"
            // Keep the detected network host so the Local + SSH view
            // can show the exact SSH command/address.
        }

        if (displayActive && activeResolution !== "") {
            actionRequestedResolution = activeResolution
            actionCommandWasStart = true
            actionCommandWasStop = false
            stateGeneration++

            actionProcess.command = [
                "bash",
                root.scriptPath,
                "start",
                activeResolution,
                displaySide,
                mode
            ]

            actionProcess.running = true
            return
        }

        actionCommandWasStart = false
        actionCommandWasStop = false
        stateGeneration++

        actionProcess.command = [
            "bash",
            root.scriptPath,
            "set-vnc-mode",
            mode
        ]

        actionProcess.running = true
    }

    // ─────────────────────────────────────────
    // Regenerate password
    // ─────────────────────────────────────────

    function regenerateVncPassword() {
        if (!networkAccess || actionProcess.running)
            return

        vncPasswordVisible = false

        actionCommandWasStart = false
        actionCommandWasStop = false

        actionProcess.command = [
            "bash",
            root.scriptPath,
            "regenerate-password"
        ]

        actionProcess.running = true
    }

    // ─────────────────────────────────────────
    // Custom resolution
    // ─────────────────────────────────────────

    function applyCustomResolution() {
        if (actionProcess.running)
            return

        var value = String(
            customResolutionInput.text || ""
        ).trim().replace(/\s+/g, "")

        customResolutionError = ""

        if (!/^\d+x\d+$/i.test(value)) {
            customResolutionError =
                "Use WIDTHxHEIGHT, e.g. 1920x1200"
            return
        }

        var parts = value.toLowerCase().split("x")
        var width = parseInt(parts[0], 10)
        var height = parseInt(parts[1], 10)

        if (isNaN(width) || isNaN(height)) {
            customResolutionError = "Invalid resolution"
            return
        }

        if (width < 320 || height < 200) {
            customResolutionError = "Minimum size is 320x200"
            return
        }

        if (width > 7680 || height > 4320) {
            customResolutionError = "Maximum size is 7680x4320"
            return
        }

        value = width + "x" + height
        customResolution = value
        customResolutionInput.text = value

        startResolution(value)
    }

    // ─────────────────────────────────────────
    // UI
    // ─────────────────────────────────────────

    KeyboardPanel {
        id: panel

        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher

        contentWidth:
            panel.fittedContentWidth(Style.space(380))

        contentHeight:
            panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent

            blocked:
                customResolutionInput.activeFocus

            onCloseRequested: root.close()

            onTabRequested: function(direction) {
                root.switchPanel(direction)
            }

            Column {
                id: content

                width: parent.width
                spacing: Style.space(5)

                // ═════════════════════════════
                // HEADER
                // ═════════════════════════════

                Item {
                    width: parent.width
                    height: Style.space(50)

                    Text {
                        id: displayIcon

                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter

                        text:
                            root.displayActive ? "󰍹" : "󰍺"

                        color: root.barForeground

                        font.family:
                            root.bar
                            ? root.bar.fontFamily
                            : Style.font.family

                        font.pixelSize: Style.font.display
                    }

                    Column {
                        anchors.left: displayIcon.right
                        anchors.leftMargin: Style.space(14)
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                            width: parent.width

                            text: "Virtual Display"

                            color: root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width

                            text:
                                root.displayActive
                                ? "ACTIVE · "
                                  + root.activeResolution
                                  + " · "
                                  + root.displaySide.toUpperCase()
                                : "DISABLED · "
                                  + root.displaySide.toUpperCase()

                            color:
                                root.displayActive
                                ? root.barForeground
                                : Qt.darker(
                                    root.barForeground,
                                    1.5
                                )

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize: Style.font.caption
                            font.bold: true
                            elide: Text.ElideRight
                        }
                    }
                }

                // ═════════════════════════════
                // POSITION
                // ═════════════════════════════

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width
                    text: "POSITION"
                    color: root.barForeground
                    opacity: 0.65
                    font.family:
                        root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.0
                }

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Repeater {
                        model: [
                            { side: "left", label: "←  LEFT" },
                            { side: "right", label: "RIGHT →" }
                        ]

                        delegate: Rectangle {
                            id: sideDelegate

                            required property var modelData

                            width:
                                (parent.width - Style.space(8)) / 2

                            height: Style.space(36)
                            radius: Style.cornerRadius

                            color:
                                root.displaySide
                                === sideDelegate.modelData.side
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
                                === sideDelegate.modelData.side
                                ? 1 : 0

                            border.color: root.barForeground
                            opacity: root.busy ? 0.55 : 1.0

                            Text {
                                anchors.centerIn: parent
                                text: sideDelegate.modelData.label
                                color: root.barForeground
                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family
                                font.pixelSize: Style.font.body
                                font.bold:
                                    root.displaySide
                                    === sideDelegate.modelData.side
                            }

                            MouseArea {
                                id: sideMouse
                                anchors.fill: parent
                                enabled: !root.busy
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor

                                onClicked: root.setSide(
                                    sideDelegate.modelData.side
                                )
                            }
                        }
                    }
                }

                // ═════════════════════════════
                // RESOLUTION
                // ═════════════════════════════

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width
                    text: "RESOLUTION"
                    color: root.barForeground
                    opacity: 0.65
                    font.family:
                        root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.0
                }

                Repeater {
                    model: root.resolutions

                    delegate: Rectangle {
                        id: resolutionDelegate

                        required property string modelData

                        width: parent.width
                        height: Style.space(34)
                        radius: Style.cornerRadius

                        color:
                            resolutionDelegate.modelData
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

                        opacity: root.busy ? 0.55 : 1.0

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            spacing: Style.space(10)

                            Text {
                                width: Style.space(18)
                                anchors.verticalCenter: parent.verticalCenter

                                text:
                                    resolutionDelegate.modelData
                                    === root.activeResolution
                                    ? "●" : "○"

                                color: root.barForeground
                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family
                                font.pixelSize: 10
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter

                                text: resolutionDelegate.modelData
                                color: root.barForeground
                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family
                                font.pixelSize: Style.font.body
                                font.bold:
                                    resolutionDelegate.modelData
                                    === root.activeResolution
                            }
                        }

                        MouseArea {
                            id: resolutionMouse
                            anchors.fill: parent
                            enabled: !root.busy
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor

                            onClicked: root.startResolution(
                                resolutionDelegate.modelData
                            )
                        }
                    }
                }

                // ═════════════════════════════
                // CUSTOM SIZE
                // ═════════════════════════════

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width
                    text: "CUSTOM SIZE"
                    color: root.barForeground
                    opacity: 0.65
                    font.family:
                        root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.0
                }

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Rectangle {
                        width: parent.width - Style.space(92)
                        height: Style.space(38)
                        radius: Style.cornerRadius

                        color:
                            Qt.rgba(
                                root.barForeground.r,
                                root.barForeground.g,
                                root.barForeground.b,
                                0.05
                            )

                        border.width:
                            customResolutionInput.activeFocus ? 1 : 0

                        border.color: root.barForeground

                        Text {
                            visible:
                                customResolutionInput.text.length === 0
                                && !customResolutionInput.activeFocus

                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter

                            text: "1920x1200"
                            color: root.barForeground
                            opacity: 0.4

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize: Style.font.body
                        }

                        TextInput {
                            id: customResolutionInput

                            anchors.fill: parent
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)

                            verticalAlignment: TextInput.AlignVCenter
                            color: root.barForeground

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

                            font.pixelSize: Style.font.body
                            inputMethodHints: Qt.ImhDigitsOnly

                            validator:
                                RegularExpressionValidator {
                                    regularExpression:
                                        /^\d{0,4}x?\d{0,4}$/
                                }

                            Keys.onReturnPressed:
                                root.applyCustomResolution()

                            Keys.onEnterPressed:
                                root.applyCustomResolution()

                            onTextChanged:
                                root.customResolutionError = ""
                        }

                        MouseArea {
                            anchors.fill: parent

                            enabled:
                                !customResolutionInput.activeFocus
                                && !root.busy

                            onClicked:
                                customResolutionInput.forceActiveFocus()
                        }
                    }

                    Rectangle {
                        width: Style.space(84)
                        height: Style.space(38)
                        radius: Style.cornerRadius

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
                        border.color: root.barForeground
                        opacity: root.busy ? 0.5 : 1.0

                        Text {
                            anchors.centerIn: parent
                            text: "Apply"
                            color: root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        MouseArea {
                            id: applyMouse
                            anchors.fill: parent
                            enabled: !root.busy
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.applyCustomResolution()
                        }
                    }
                }

                Text {
                    visible: root.customResolutionError !== ""
                    width: parent.width
                    text: root.customResolutionError
                    color: root.barForeground
                    opacity: 0.75
                    font.family:
                        root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                }

                // ═════════════════════════════
                // VNC ACCESS
                // ═════════════════════════════

                PanelSeparator {
                    foreground: root.barForeground
                }

                Text {
                    width: parent.width
                    text: "VNC ACCESS"
                    color: root.barForeground
                    opacity: 0.65
                    font.family:
                        root.bar ? root.bar.fontFamily : Style.font.family
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
                                mode: "local",
                                label: "󰌆  LOCAL + SSH"
                            },
                            {
                                mode: "network",
                                label: "󰖩  NETWORK"
                            }
                        ]

                        delegate: Rectangle {
                            id: vncModeDelegate

                            required property var modelData

                            width:
                                (parent.width - Style.space(8)) / 2

                            height: Style.space(38)
                            radius: Style.cornerRadius

                            color:
                                root.vncMode
                                === vncModeDelegate.modelData.mode
                                ? Qt.rgba(
                                    root.barForeground.r,
                                    root.barForeground.g,
                                    root.barForeground.b,
                                    0.12
                                )
                                : vncModeMouse.containsMouse
                                  ? Qt.rgba(
                                      root.barForeground.r,
                                      root.barForeground.g,
                                      root.barForeground.b,
                                      0.06
                                  )
                                  : "transparent"

                            border.width:
                                root.vncMode
                                === vncModeDelegate.modelData.mode
                                ? 1 : 0

                            border.color: root.barForeground
                            opacity: root.busy ? 0.55 : 1.0

                            Text {
                                anchors.centerIn: parent
                                text: vncModeDelegate.modelData.label
                                color: root.barForeground

                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family

                                font.pixelSize: Style.font.caption

                                font.bold:
                                    root.vncMode
                                    === vncModeDelegate.modelData.mode
                            }

                            MouseArea {
                                id: vncModeMouse
                                anchors.fill: parent
                                enabled: !root.busy
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor

                                onClicked: root.setVncMode(
                                    vncModeDelegate.modelData.mode
                                )
                            }
                        }
                    }
                }

                // ═════════════════════════════
                // VNC DETAILS
                // ═════════════════════════════

                Item {
                    width: parent.width
                    height:
                        root.networkAccess
                        ? networkDetails.implicitHeight
                        : localDetails.implicitHeight

                    Column {
                        id: localDetails

                        visible: !root.networkAccess
                        width: parent.width
                        spacing: Style.space(4)

                        Text {
                            width: parent.width
                            text: "󰌆  LOCAL + SSH"
                            color: root.barForeground
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            text: "Bind: 127.0.0.1:5900"
                            color: root.barForeground
                            opacity: 0.8
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            width: parent.width
                            text: "Remote access requires SSH tunneling."
                            color: root.barForeground
                            opacity: 0.8
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.Wrap
                        }

                        Rectangle {
                            width: parent.width
                            height: Style.space(48)
                            radius: Style.cornerRadius
                            color:
                                Qt.rgba(
                                    root.barForeground.r,
                                    root.barForeground.g,
                                    root.barForeground.b,
                                    0.06
                                )
                            border.width: 1
                            border.color:
                                Qt.rgba(
                                    root.barForeground.r,
                                    root.barForeground.g,
                                    root.barForeground.b,
                                    0.12
                                )

                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: Style.space(8)
                                anchors.rightMargin: Style.space(8)
                                anchors.topMargin: Style.space(4)
                                anchors.bottomMargin: Style.space(4)
                                text: root.effectiveSshCommand
                                color: root.barForeground
                                opacity: 0.95
                                font.family:
                                    root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.Wrap
                            }
                        }

                        Text {
                            width: parent.width
                            text: "VNC client: localhost:5900"
                            color: root.barForeground
                            opacity: 0.8
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }

                    Column {
                        id: networkDetails

                        visible: root.networkAccess
                        width: parent.width
                        spacing: Style.space(4)

                        Text {
                            width: parent.width
                            text: "󰖩  NETWORK ACCESS · TLS + PASSWORD"
                            color: root.barForeground
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            text: "Bind: 0.0.0.0:5900"
                            color: root.barForeground
                            opacity: 0.9
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            width: parent.width
                            text: "Connect using:"
                            color: root.barForeground
                            opacity: 0.9
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            width: parent.width
                            text: root.networkConnectionsText()
                            color: root.barForeground
                            opacity: 0.9
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.Wrap
                        }

                        Text {
                            width: parent.width
                            text:
                                "Username: "
                                + root.effectiveUsername
                            color: root.barForeground
                            opacity: 0.9
                            font.family:
                                root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(4)

                            Text {
                                width: parent.width - Style.space(75)
                                text:
                                    root.vncPasswordVisible
                                    ? "Password: "
                                      + (
                                          root.vncPassword !== ""
                                          ? root.vncPassword
                                          : "Unavailable"
                                      )
                                    : "Password: ••••••••••••••••"
                                color: root.barForeground
                                opacity: 0.95
                                font.family:
                                    root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                width: Style.space(70)
                                height: Style.space(28)
                                radius: Style.cornerRadius
                                color:
                                    passwordMouse.containsMouse
                                    ? Qt.rgba(
                                        root.barForeground.r,
                                        root.barForeground.g,
                                        root.barForeground.b,
                                        0.10
                                    )
                                    : "transparent"

                                Text {
                                    anchors.centerIn: parent
                                    text:
                                        root.vncPasswordVisible
                                        ? "Hide"
                                        : "Show"
                                    color: root.barForeground
                                    font.family:
                                        root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                }

                                MouseArea {
                                    id: passwordMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked:
                                        root.vncPasswordVisible =
                                            !root.vncPasswordVisible
                                }
                            }
                        }
                    }
                }

                // ═════════════════════════════
                // NETWORK WARNING
                // ═════════════════════════════

                Rectangle {
                    visible: root.networkAccess
                    width: parent.width

                    height:
                        warningColumn.implicitHeight
                        + Style.space(18)

                    radius: Style.cornerRadius

                    color:
                        Qt.rgba(
                            root.barForeground.r,
                            root.barForeground.g,
                            root.barForeground.b,
                            0.10
                        )

                    border.width: 1
                    border.color: root.barForeground

                    Row {
                        anchors.fill: parent
                        anchors.margins: Style.space(9)
                        spacing: Style.space(9)

                        Text {
                            anchors.top: parent.top
                            text: "⚠"
                            color: root.barForeground
                            font.pixelSize: Style.font.title
                        }

                        Column {
                            id: warningColumn

                            width:
                                parent.width - Style.space(34)

                            spacing: Style.space(2)

                            Text {
                                width: parent.width
                                text: "NETWORK ACCESS ENABLED"
                                color: root.barForeground

                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family

                                font.pixelSize: Style.font.caption
                                font.bold: true
                            }

                            Text {
                                width: parent.width

                                text:
                                    "Other devices on your Wi-Fi or Ethernet "
                                    + "network can connect.\n"
                                    + "Use only on a trusted network."

                                color: root.barForeground
                                opacity: 0.9

                                font.family:
                                    root.bar
                                    ? root.bar.fontFamily
                                    : Style.font.family

                                font.pixelSize: Style.font.caption
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                // ═════════════════════════════
                // REGENERATE PASSWORD
                // ═════════════════════════════

                Rectangle {
                    visible: root.networkAccess
                    width: parent.width
                    height: Style.space(38)
                    radius: Style.cornerRadius

                    color:
                        regenerateMouse.containsMouse
                        ? Qt.rgba(
                            root.barForeground.r,
                            root.barForeground.g,
                            root.barForeground.b,
                            0.06
                        )
                        : "transparent"

                    opacity: root.busy ? 0.5 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: "↻  Regenerate VNC password"
                        color: root.barForeground

                        font.family:
                            root.bar
                            ? root.bar.fontFamily
                            : Style.font.family

                        font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                        id: regenerateMouse
                        anchors.fill: parent
                        enabled: !root.busy
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        onClicked:
                            root.regenerateVncPassword()
                    }
                }

                // ═════════════════════════════
                // DISABLE
                // ═════════════════════════════

                PanelSeparator {
                    foreground: root.barForeground
                }

                Rectangle {
                    width: parent.width
                    height: Style.space(38)
                    radius: Style.cornerRadius

                    color:
                        disableMouse.containsMouse
                        ? Qt.rgba(1, 0, 0, 0.08)
                        : "transparent"

                    opacity: root.busy ? 0.5 : 1.0

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(10)
                        spacing: Style.space(10)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰅖"
                            color: root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize: Style.font.body
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Disable virtual display"
                            color: root.barForeground

                            font.family:
                                root.bar
                                ? root.bar.fontFamily
                                : Style.font.family

                            font.pixelSize: Style.font.body
                        }
                    }

                    MouseArea {
                        id: disableMouse
                        anchors.fill: parent
                        enabled: !root.busy
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.stopDisplay()
                    }
                }
            }
        }
    }

    // ═════════════════════════════════════════
    // ACTION PROCESS
    // ═════════════════════════════════════════

    Process {
        id: actionProcess

        running: false
        command: []

        stdout: StdioCollector {
            id: actionOutput
        }

        stderr: StdioCollector {
            id: actionError
        }

        onExited: function(exitCode) {
            if (exitCode === 0) {
                if (actionCommandWasStart) {
                    root.activeResolution =
                        root.actionRequestedResolution

                    root.waitingForActiveStatus = true
                    root.activeStatusMisses = 0
                } else if (actionCommandWasStop) {
                    root.activeResolution = ""
                    root.waitingForActiveStatus = false
                    root.activeStatusMisses = 0
                }
            } else {
                console.warn(
                    "VDCreate command failed:",
                    actionError.text.trim()
                )

                if (actionCommandWasStart) {
                    root.activeResolution = ""
                    root.waitingForActiveStatus = false
                    root.activeStatusMisses = 0
                }
            }

            actionCommandWasStart = false
            actionCommandWasStop = false

            root.requestStatusRefresh(500)
        }
    }

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

            onStreamFinished: {
                // Discard a result from a status request that started
                // before the latest display-changing action.
                if (root.statusRequestGeneration !== root.stateGeneration) {
                    root.pendingStatusRefresh = true
                    root.requestStatusRefresh(150)
                    return
                }

                var value = String(statusOutput.text || "").trim()

                if (value === "")
                    return

                var parts = value.split("|")

                if (parts.length < 3)
                    return

                var resolution = parts[0]
                var side = parts[1]
                var mode = parts[2]
                var connectHost = parts.length > 4 ? parts[4] : ""
                var username = parts.length > 5 ? parts[5] : ""
                var password = parts.length > 6 ? parts[6] : ""
                var sshCommand = parts.length > 7 ? parts[7] : ""
                var networkAddresses =
                    parts.length > 8 ? parts[8] : ""

                if (side === "left" || side === "right")
                    root.displaySide = side

                if (mode === "local" || mode === "network")
                    root.vncMode = mode

                if (connectHost !== "")
                    root.vncConnectHost = connectHost

                if (username !== "")
                    root.vncUsername = username

                if (password !== "")
                    root.vncPassword = password

                if (sshCommand !== "")
                    root.sshCommand = sshCommand

                root.networkAddressesCsv =
                    networkAddresses

                if (resolution !== "off" && resolution !== "") {
                    root.activeResolution = resolution
                    root.waitingForActiveStatus = false
                    root.activeStatusMisses = 0
                } else if (root.waitingForActiveStatus) {
                    // Keep the successful action state while Hyprland settles.
                    root.activeStatusMisses++

                    if (root.activeStatusMisses < 8) {
                        root.pendingStatusRefresh = true
                        root.requestStatusRefresh(350)
                    } else {
                        root.waitingForActiveStatus = false
                        root.activeStatusMisses = 0
                        root.activeResolution = ""
                    }
                } else {
                    root.activeResolution = ""
                }

                root.vncBindAddress =
                    root.vncMode === "network"
                    ? "0.0.0.0:5900"
                    : "127.0.0.1:5900"

                if (root.pendingStatusRefresh) {
                    root.pendingStatusRefresh = false
                    root.requestStatusRefresh(250)
                }
            }
        }

        stderr: StdioCollector {
            id: statusError
        }

        onExited: function(exitCode) {
            if (exitCode !== 0) {
                console.warn(
                    "VDCreate status failed:",
                    statusError.text.trim()
                )
            }
        }
    }

    // ═════════════════════════════════════════
    // STATUS RETRY TIMER
    // ═════════════════════════════════════════

    Timer {
        id: statusRetryTimer
        interval: 250
        repeat: false

        onTriggered: root.refreshStatus()
    }

    // ═════════════════════════════════════════
    // PERIODIC STATUS SYNCHRONIZATION
    // ═════════════════════════════════════════

    Timer {
        interval: 3000
        running: root.opened
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            if (!root.actionProcess.running)
                root.refreshStatus()
        }
    }
}
