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
// Upper triangle — the half a causal mask hides, used as a VRAM gauge: the
// share of the card the model is holding. It fills outward from the diagonal
// to the far corner, its cells splitting the card evenly (6 on a 4x4 grid, so
// ~2.7 GB each on 16 GB; a partial cell is drawn smaller), and drains when the
// model sleeps or unloads. Each cell has its own colour on a low -> mid -> high
// gradient in fill order, so the colour at the tip says how full the card is
// as well as the count does. A soft glow travels through the filled cells now
// and then (and sweeps to the new level when it changes) without ever dimming
// them, so the amount stays readable. When the whole card is nearly full,
// every filled cell takes the high colour and the glow quickens.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property string mode: "ready"
  property int grid: 4
  property color gaugeLow: Commons.Color.accent      // first cell
  property color gaugeMid: gaugeLow                   // middle of the gradient
  property color gaugeHigh: Commons.Color.urgent      // far corner, and the "card nearly full" colour
  property real gauge: 0          // 0..1 share of VRAM held by the model
  property bool warn: false       // whole GPU nearly full
  property real wave: -1          // glow position, 0..1 while a sweep runs

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

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  // Gradient colour for a fill position 0..1 (low -> mid -> high).
  function gradientAt(t) {
    return t < 0.5 ? mix(gaugeLow, gaugeMid, t * 2) : mix(gaugeMid, gaugeHigh, (t - 0.5) * 2)
  }

  // 0..1 glow on the i-th filled cell while a sweep passes over it.
  function glowAt(i) {
    var filled = gauge * upperCount
    if (wave < 0 || i >= filled) return 0
    var pos = wave * (filled + 1.5) - 0.75
    return Math.max(0, 1 - Math.abs(i + 0.5 - pos) / 0.9)
  }

  function gaugeCellColor(r, c) {
    var i = upperIndex(r, c)
    var base = warn ? gaugeHigh : gradientAt(upperCount > 1 ? i / (upperCount - 1) : 1)
    return mix(base, Qt.rgba(1, 1, 1, 1), 0.5 * glowAt(i))
  }

  // [opacity, scale] for an upper (gauge) cell.
  function gaugeLook(r, c) {
    if (mode === "stopped") return [0.16, 0.3]
    var i = upperIndex(r, c)
    var amount = Math.max(0, Math.min(1, gauge * upperCount - i))
    if (amount <= 0.02) return [0.22, 0.3]
    // filled cells stay bright (the count is the reading); a partial one is smaller
    return [Math.min(1, 0.72 + 0.28 * amount + 0.2 * glowAt(i)), 0.45 + 0.55 * amount]
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

  // The glow: one sweep through the filled cells, then a rest. It runs only
  // while something is in VRAM and animations are on.
  SequentialAnimation {
    id: sweep
    running: root.animate && root.mode !== "stopped" && root.gauge > 0.01
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "wave"; from: 0; to: 1; duration: root.warn ? 900 : 1500; easing.type: Easing.InOutSine }
    PropertyAction { target: root; property: "wave"; value: -1 }
    PauseAnimation { duration: root.warn ? 1200 : 3500 }
    onRunningChanged: if (!running) root.wave = -1
  }
  // A new level gets a sweep right away, so the change is easy to notice.
  onGaugeChanged: if (sweep.running && Math.abs(gauge - _shownGauge) > 0.02) { _shownGauge = gauge; sweep.restart() }
  property real _shownGauge: 0

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
      color: upper ? root.gaugeCellColor(row, col) : root.color
      opacity: look[0]
      scale: look[1]

      // smoothing would smear the moving glow, so gauge cells skip it mid-sweep
      Behavior on opacity { enabled: !(cellItem.upper && root.wave >= 0); NumberAnimation { duration: Style.duration(110); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on color { enabled: !(cellItem.upper && root.wave >= 0); ColorAnimation { duration: Style.duration(180) } }
    }
  }
}
