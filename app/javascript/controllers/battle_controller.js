import { Controller } from "@hotwired/stimulus"

// Must mirror the geometry baked into battles/_field.html.erb.
const VIEW = { width: 1000, height: 460, margin: 46, span: 908, ground: 372 }
const MUZZLE = { forward: 32, height: 28 }
const MIN_SEPARATION = 12
const TANK_HALF = 2.5

const worldToX = (unit) => VIEW.margin + (unit / 100) * VIEW.span
const xToWorld = (x) => ((x - VIEW.margin) / VIEW.span) * 100
const clamp = (value, min, max) => Math.max(min, Math.min(max, value))
const easeInOut = (p) => (p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2)

const quadPoint = (from, control, to, t) => {
  const mt = 1 - t
  return {
    x: mt * mt * from.x + 2 * mt * t * control.x + t * t * to.x,
    y: mt * mt * from.y + 2 * mt * t * control.y + t * t * to.y
  }
}

export default class extends Controller {
  static targets = [
    "scene", "tankOne", "tankTwo", "ghost", "aimArc", "aimDrop", "crosshair",
    "crosshairLabel", "projectile", "explosion", "panel", "aimForm", "aimInput",
    "fireButton", "moveInput", "moveButton", "targetOut", "angleOut", "positionOut",
    "hpBarOne", "hpBarTwo", "hpTextOne", "hpTextTwo"
  ]

  static values = {
    id: Number,
    turn: Number,
    role: String,
    status: String,
    playerOnePosition: Number,
    playerTwoPosition: Number,
    playerOneMaxHp: Number,
    playerTwoMaxHp: Number,
    attackerSide: String,
    mySide: String,
    committed: Boolean,
    replay: Object
  }

  connect() {
    this.animating = false
    this.aimWorld = null
    this.onPointerMove = this.onPointerMove.bind(this)
    this.onPointerLeave = this.onPointerLeave.bind(this)

    this.sceneTarget.addEventListener("pointermove", this.onPointerMove)
    this.sceneTarget.addEventListener("pointerleave", this.onPointerLeave)

    this.placeTanks()
    this.syncCursor()
    this.restorePending()
  }

  disconnect() {
    this.sceneTarget.removeEventListener("pointermove", this.onPointerMove)
    this.sceneTarget.removeEventListener("pointerleave", this.onPointerLeave)
  }

  // A round only ever resolves once, so a replay id we have not shown in this
  // tab is by definition a round that just happened.
  replayValueChanged(replay) {
    if (!replay || !replay.id) return

    const key = `gwars.battle.${this.idValue}.replay`
    if (Number(sessionStorage.getItem(key) || 0) >= replay.id) return
    sessionStorage.setItem(key, String(replay.id))

    this.playReplay(replay)
  }

  playerOnePositionValueChanged() {
    if (!this.animating) this.placeTanks()
  }

  playerTwoPositionValueChanged() {
    if (!this.animating) this.placeTanks()
  }

  committedValueChanged() {
    this.syncCursor()
  }

  // ---------------------------------------------------------------- aiming

  onPointerMove(event) {
    if (!this.canAim()) return

    const world = clamp(xToWorld(this.sceneX(event)), 0, 100)
    this.aimWorld = world
    this.drawAim(world)

    // Throttled so a live refresh mid-aim doesn't wipe the shot being lined up.
    const now = performance.now()
    if (!this.lastAimSave || now - this.lastAimSave > 250) {
      this.lastAimSave = now
      this.savePending({ aim: world })
    }
  }

  onPointerLeave() {
    if (!this.canAim() || this.aimWorld !== null) return
    this.hideAim()
  }

  drawAim(world) {
    const from = this.muzzleFor(this.attackerSideValue, this.positionOf(this.attackerSideValue))
    const to = { x: worldToX(world), y: VIEW.ground }
    const control = this.controlPoint(from, to)

    this.aimArcTarget.setAttribute("d", `M ${from.x} ${from.y} Q ${control.x} ${control.y} ${to.x} ${to.y}`)
    this.aimArcTarget.setAttribute("opacity", "1")

    this.crosshairTarget.setAttribute("transform", `translate(${to.x}, ${VIEW.ground - 16})`)
    this.crosshairTarget.setAttribute("opacity", "1")
    this.crosshairLabelTarget.textContent = world.toFixed(0)

    this.aimDropTarget.setAttribute("x1", to.x)
    this.aimDropTarget.setAttribute("x2", to.x)
    this.aimDropTarget.setAttribute("y1", VIEW.ground - 16)
    this.aimDropTarget.setAttribute("y2", VIEW.ground + 34)
    this.aimDropTarget.setAttribute("opacity", "1")

    if (this.hasAimInputTarget) this.aimInputTarget.value = world.toFixed(2)
    if (this.hasFireButtonTarget) this.fireButtonTarget.disabled = false
    if (this.hasTargetOutTarget) this.targetOutTarget.textContent = world.toFixed(1)
    if (this.hasAngleOutTarget) {
      const angle = Math.atan2(from.y - control.y, control.x - from.x) * (180 / Math.PI)
      this.angleOutTarget.textContent = `${Math.abs(angle).toFixed(0)}°`
    }
  }

  hideAim() {
    this.aimArcTarget.setAttribute("opacity", "0")
    this.crosshairTarget.setAttribute("opacity", "0")
    this.aimDropTarget.setAttribute("opacity", "0")
  }

  controlPoint(from, to) {
    const rise = clamp(Math.abs(to.x - from.x) * 0.55, 140, 300)
    const topY = Math.min(from.y, to.y)
    return { x: (from.x + to.x) / 2, y: 2 * (topY - rise) - (from.y + to.y) / 2 }
  }

  // ---------------------------------------------------------------- moving

  selectMove(event) {
    const delta = Number(event.currentTarget.dataset.delta)
    this.applyMove(delta)
    this.savePending({ delta })
  }

  applyMove(delta) {
    const landing = this.clampPosition(this.positionOf(this.mySideValue) + delta)

    this.moveInputTarget.value = delta
    this.moveButtonTargets.forEach((button) => {
      button.classList.toggle("is-active", Number(button.dataset.delta) === delta)
    })

    this.ghostTarget.setAttribute("transform", `translate(${worldToX(landing)}, ${VIEW.ground})`)
    this.ghostTarget.setAttribute("opacity", delta === 0 ? "0" : "0.45")
    if (this.hasPositionOutTarget) this.positionOutTarget.textContent = landing
  }

  // A live refresh from the opponent re-renders the panel, which would silently
  // revert an uncommitted choice to the server-rendered default. Put it back.
  restorePending() {
    if (this.committedValue || this.statusValue !== "active") return

    const pending = this.loadPending()
    if (!pending) return

    if (this.roleValue === "defender" && pending.delta != null && this.hasMoveInputTarget) {
      this.applyMove(pending.delta)
    } else if (this.roleValue === "attacker" && pending.aim != null && this.hasAimInputTarget) {
      this.aimWorld = pending.aim
      this.drawAim(pending.aim)
    }
  }

  pendingKey() {
    return `gwars.battle.${this.idValue}.turn.${this.turnValue}.pending`
  }

  savePending(data) {
    sessionStorage.setItem(this.pendingKey(), JSON.stringify(data))
  }

  loadPending() {
    try {
      return JSON.parse(sessionStorage.getItem(this.pendingKey()))
    } catch {
      return null
    }
  }

  clampPosition(position) {
    const opponent = this.positionOf(this.mySideValue === "one" ? "two" : "one")
    const kept = position < opponent
      ? Math.min(position, opponent - MIN_SEPARATION)
      : Math.max(position, opponent + MIN_SEPARATION)

    return Math.round(clamp(kept, TANK_HALF, 100 - TANK_HALF))
  }

  // --------------------------------------------------------------- replay

  async playReplay(turn) {
    const defenderSide = turn.attackerSide === "one" ? "two" : "one"

    this.animating = true
    this.hideAim()
    this.setPanelLocked(true)
    this.ghostTarget.setAttribute("opacity", "0")

    this.setTank(defenderSide, turn.defenderFrom)
    this.setHp(defenderSide, turn.hpBefore)

    if (this.prefersReducedMotion()) {
      this.finishReplay(turn, defenderSide)
      return
    }

    const from = this.muzzleFor(turn.attackerSide, turn.attackerPosition)
    const to = { x: worldToX(turn.aimX), y: VIEW.ground }
    const control = this.controlPoint(from, to)

    // The defender rolls while the shell is still in the air — that overlap is
    // the whole game: you are shooting at where you think they will be.
    const rolling = this.tween(700, (p) => {
      const eased = easeInOut(p)
      this.setTank(defenderSide, turn.defenderFrom + (turn.defenderTo - turn.defenderFrom) * eased)
    })

    this.projectileTarget.setAttribute("opacity", "1")
    await this.tween(1100, (p) => {
      const point = quadPoint(from, control, to, p)
      this.projectileTarget.setAttribute("cx", point.x)
      this.projectileTarget.setAttribute("cy", point.y)
    })
    this.projectileTarget.setAttribute("opacity", "0")
    await rolling

    await this.explode(to, turn.hit)
    if (turn.damage > 0) await this.drainHp(defenderSide, turn.hpBefore, turn.hpAfter)

    this.finishReplay(turn, defenderSide)
  }

  finishReplay(turn, defenderSide) {
    this.setTank(defenderSide, turn.defenderTo)
    this.setHp(defenderSide, turn.hpAfter)
    this.animating = false
    this.setPanelLocked(false)
    this.syncCursor()
  }

  async explode(point, hit) {
    this.explosionTarget.setAttribute("transform", `translate(${point.x}, ${point.y})`)
    this.sceneTarget.classList.toggle("is-shaking", hit)

    await this.tween(hit ? 520 : 340, (p) => {
      const circle = this.explosionTarget.firstElementChild
      circle.setAttribute("r", (hit ? 18 : 8) + p * (hit ? 52 : 22))
      this.explosionTarget.setAttribute("opacity", String(1 - p))
    })

    this.explosionTarget.setAttribute("opacity", "0")
    this.sceneTarget.classList.remove("is-shaking")
  }

  drainHp(side, before, after) {
    return this.tween(520, (p) => {
      this.setHp(side, Math.round(before + (after - before) * p))
    })
  }

  // --------------------------------------------------------------- helpers

  canAim() {
    return this.roleValue === "attacker" &&
      this.statusValue === "active" &&
      !this.committedValue &&
      !this.animating
  }

  syncCursor() {
    this.sceneTarget.classList.toggle("is-aimable", this.canAim())
    if (!this.canAim()) this.hideAim()
  }

  placeTanks() {
    this.setTank("one", this.playerOnePositionValue)
    this.setTank("two", this.playerTwoPositionValue)
  }

  setTank(side, unit) {
    const target = side === "one" ? this.tankOneTarget : this.tankTwoTarget
    target.setAttribute("transform", `translate(${worldToX(unit)}, ${VIEW.ground})`)
  }

  setHp(side, value) {
    const max = side === "one" ? this.playerOneMaxHpValue : this.playerTwoMaxHpValue
    const bar = side === "one" ? this.hpBarOneTarget : this.hpBarTwoTarget
    const text = side === "one" ? this.hpTextOneTarget : this.hpTextTwoTarget

    bar.style.width = `${clamp((value / max) * 100, 0, 100)}%`
    text.textContent = value
  }

  positionOf(side) {
    return side === "one" ? this.playerOnePositionValue : this.playerTwoPositionValue
  }

  muzzleFor(side, unit) {
    const facing = side === "one" ? 1 : -1
    return { x: worldToX(unit) + facing * MUZZLE.forward, y: VIEW.ground - MUZZLE.height }
  }

  setPanelLocked(locked) {
    if (this.hasPanelTarget) this.panelTarget.classList.toggle("is-busy", locked)
  }

  sceneX(event) {
    const rect = this.sceneTarget.getBoundingClientRect()
    const scale = Math.min(rect.width / VIEW.width, rect.height / VIEW.height)
    const offset = (rect.width - VIEW.width * scale) / 2
    return (event.clientX - rect.left - offset) / scale
  }

  prefersReducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }

  tween(duration, step) {
    return new Promise((resolve) => {
      const start = performance.now()
      const frame = (now) => {
        const p = Math.min(1, (now - start) / duration)
        step(p)
        p < 1 ? requestAnimationFrame(frame) : resolve()
      }
      requestAnimationFrame(frame)
    })
  }
}
