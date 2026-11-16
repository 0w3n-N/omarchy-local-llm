import QtQuick
import qs.Commons
import qs.Commons as Commons

// A square split on its diagonal into two triangles.
//
// Lower triangle (incl. the diagonal), bar colour — the causal attention mask
// every decoder-only transformer uses so token i only sees tokens 0..i. It acts
// out what the local model is doing:
//   stopped  — empty matrix, faint dots only
//   idle     — just the diagonal: each token attends only to itself
//   loading  — mask cells fill in raster order as weights stream into VRAM
//   ready    — the full causal triangle
//   asleep   — the triangle contracts to points (weights freed)
//   thinking — autoregressive decode: the query row walks down the mask, its
//              attention weights flickering, rows above settled, rows below
//              still masked
//
// Upper triangle, second colour — the half a causal mask hides, used as a VRAM
// gauge: the share of the card the model is holding. It fills outward from the
// diagonal to the far corner, its cells splitting the card evenly (6 on a
// 4x4 grid, so ~2.7 GB each on 16 GB; partial cells grow),
// drains when the model sleeps or unloads, and turns to the warning colour
// when the whole card is nearly full.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property string mode: "ready"
  property int grid: 4
  property color gaugeColor: Commons.Color.accent
  property color warnColor: Commons.Color.urgent
  property real gauge: 0          // 0..1 share of VRAM held by the model
  property bool warn: false       // whole GPU nearly full

  readonly property real aspectRatio: 1.0
  // With animations off Style.duration() is 0: show still frames, never loop.
  readonly property bool animate: Style.duration(100) > 0

  readonly property real gapRatio: 0.34
  readonly property real cell: iconSize / (grid + (grid - 1) * gapRatio)
  readonly property real pitch: cell * (1 + gapRatio)
  readonly property int lowerCount: grid * (grid + 1) / 2
  readonly property int upperCount: grid * (grid - 1) / 2

  property int step: 0
  property var weights: []

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  function rerollRow(row) {
    // Random attention weights for one query row, max-normalised so the
    // strongest key is always fully lit (like a softmax peak).
    var w = weights.slice()
    if (w.length !== grid * grid) { w = []; for (var k = 0; k < grid * grid; k++) w.push(0.6) }
    var peak = 0
    var raw = []
    for (var c = 0; c <= row; c++) { var v = 0.15 + Math.pow(Math.random(), 1.6); raw.push(v); peak = Math.max(peak, v) }
    for (c = 0; c <= row; c++) w[row * grid + c] = 0.3 + 0.7 * raw[c] / peak
    weights = w
  }

  // Raster index of a lower-triangle cell (0 .. lowerCount-1).
  function lowerIndex(r, c) { return r * (r + 1) / 2 + c }

  // Fill order of an upper cell: band by band away from the diagonal
  // (c - r = 1, 2, ...), top to bottom inside a band; the far corner is last.
  function upperIndex(r, c) {
    var d = c - r
    return (d - 1) * grid - (d - 1) * d / 2 + r
  }

  // [opacity, scale] for an upper (gauge) cell.
  function gaugeLook(r, c) {
    if (mode === "stopped") return [0.16, 0.3]
    var amount = Math.max(0, Math.min(1, gauge * upperCount - upperIndex(r, c)))
    if (amount <= 0.02) return [0.22, 0.3]
    return [0.45 + 0.55 * amount, 0.45 + 0.55 * amount]
  }

  // [opacity, scale] for one cell in the current mode/step.
  function cellLook(r, c) {
    if (c > r) return gaugeLook(r, c)
    switch (mode) {
    case "stopped": return [0.28, 0.3]
    case "idle": return r === c ? [0.7, 0.85] : [0.3, 0.3]
    case "asleep": return [r === c ? 0.75 : 0.5, 0.42]
    case "loading":
      if (!animate) return [0.55, 0.85]
      return lowerIndex(r, c) < step % (lowerCount + 3) ? [1, 1] : [0.3, 0.3]
    case "thinking":
      if (!animate) return [1, 1]
      var q = step % grid
      if (r < q) return [0.72, 1]
      if (r > q) return [0.3, 0.4]
      var w = weights[r * grid + c]
      return [w === undefined ? 1 : w, 1]
    default: return [1, 1]   // ready
    }
  }

  onModeChanged: { step = 0; if (mode === "thinking") rerollRow(0) }

  Timer {
    running: root.animate && (root.mode === "thinking" || root.mode === "loading")
    interval: root.mode === "thinking" ? 150 : 90
    repeat: true
    onTriggered: {
      root.step += 1
      if (root.mode === "thinking") root.rerollRow(root.step % root.grid)
    }
  }

  Repeater {
    model: root.grid * root.grid

    Rectangle {
      id: cellItem
      required property int index
      readonly property int row: Math.floor(index / root.grid)
      readonly property int col: index % root.grid
      readonly property bool upper: col > row
      readonly property var look: root.cellLook(row, col)

      x: col * root.pitch
      y: row * root.pitch
      width: root.cell
      height: root.cell
      radius: root.cell * 0.24 * (look[1] < 0.6 ? 2 : 1)   // dots go round
      antialiasing: true
      color: upper ? (root.warn ? root.warnColor : root.gaugeColor) : root.color
      opacity: look[0]
      scale: look[1]

      Behavior on opacity { NumberAnimation { duration: Style.duration(110); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: Style.duration(180) } }
    }
  }
}
