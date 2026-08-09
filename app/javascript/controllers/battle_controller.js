import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

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

const ROLE_LABELS = {
  attacker: "YOUR TURN: AIM & FIRE",
  defender: "YOUR TURN: MOVE",
  pending: "NOT STARTED",
  finished: "BATTLE OVER"
}

export default class extends Controller {
  static targets = [
    "scene", "tankOne", "tankTwo", "ghost", "aimArc", "aimDrop", "crosshair",
    "crosshairLabel", "projectile", "explosion",
    "hpTextOne", "hpTextTwo", "hpBarOne", "hpBarTwo", "turnNumber", "roleLabel",
    "aimPanel", "infoPanel", "movePanel", "waitPanel", "acceptPanel", "resultPanel",
    "fireButton", "moveButton", "targetOut", "angleOut", "positionOut",
    "waitTitle", "waitNote", "resultTitle", "resultNote", "ticker", "error"
  ]

  static values = {
    id: Number,
    mySide: String,
    nameOne: String,
    nameTwo: String,
    maxDamage: Number,
    state: Object
  }

  connect() {
    this.animating = false
    this.aimWorld = null
    this.pendingDelta = 0
    this.seenReplayId = 0

    this.onPointerMove = this.onPointerMove.bind(this)
    this.onPointerLeave = this.onPointerLeave.bind(this)
    this.sceneTarget.addEventListener("pointermove", this.onPointerMove)
    this.sceneTarget.addEventListener("pointerleave", this.onPointerLeave)

    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "BattleChannel", id: this.idValue },
      { received: (state) => this.applyState(state, false) }
    )

    this.applyState(this.stateValue, true)
  }

  disconnect() {
    this.sceneTarget.removeEventListener("pointermove", this.onPointerMove)
    this.sceneTarget.removeEventListener("pointerleave", this.onPointerLeave)
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
  }

  // ----------------------------------------------------------------- state

  applyState(state, initial) {
    if (!state || !state.status) return

    this.state = state
    const replay = state.replay

    if (replay && replay.id > this.seenReplayId) {
      this.seenReplayId = replay.id
      // On a fresh page load the state already reflects the finished round, so
      // there is nothing to play back.
      if (!initial && !this.animating) {
        this.playReplay(replay)
        return
      }
    }

    this.renderState()
  }

  renderState() {
    // Repainting mid-animation would snap tanks and HP to their final values;
    // playReplay renders again once it finishes.
    if (this.animating) return

    const state = this.state
    const role = this.role()

    this.placeTanks()
    this.setHp("one", state.hp.one)
    this.setHp("two", state.hp.two)

    this.turnNumberTarget.textContent = state.status === "pending" ? "READY?" : `TURN ${state.turnNumber}`
    this.roleLabelTarget.textContent = ROLE_LABELS[role]
    this.roleLabelTarget.className = `hud-turn-role hud-turn-role--${role}`

    this.renderPanels(role)
    this.renderTicker(role)
    this.syncCursor()
  }

  renderPanels(role) {
    const state = this.state
    const committed = role === "attacker" ? state.committed.attacker : state.committed.defender
    const acceptable = state.status === "pending" && this.mySideValue === "two"

    this.toggle(this.aimPanelTarget, role === "attacker" && !committed)
    this.toggle(this.infoPanelTarget, role === "attacker" && !committed)
    this.toggle(this.movePanelTarget, role === "defender" && !committed)
    this.toggle(this.acceptPanelTarget, acceptable)
    this.toggle(this.resultPanelTarget, state.status === "finished")

    const waiting = (state.status === "active" && committed) ||
      (state.status === "pending" && !acceptable)
    this.toggle(this.waitPanelTarget, waiting)

    if (waiting) {
      const pending = state.status === "pending"
      this.waitTitleTarget.textContent = pending ? "WAITING FOR OPPONENT" : "LOCKED IN"
      this.waitNoteTarget.textContent = pending
        ? `${this.nameValue("two")} has not accepted the challenge yet.`
        : role === "attacker"
          ? "Shot locked in. Waiting for the enemy to move…"
          : "Move locked in. Waiting for the enemy to fire…"
    }

    if (state.status === "finished") {
      const won = state.winnerSide === this.mySideValue
      this.resultTitleTarget.textContent = won ? "VICTORY" : "DEFEAT"
      this.resultNoteTarget.textContent =
        `${this.nameValue(state.winnerSide)} wins after ${state.turnNumber} turns.`
    }
  }

  renderTicker(role) {
    const state = this.state
    const active = state.status === "active"
    this.toggle(this.tickerTarget, active)
    if (!active) return

    this.tickerTarget.textContent = role === "attacker"
      ? (state.committed.defender ? "Enemy has committed their move." : "Enemy is deciding where to roll…")
      : (state.committed.attacker ? "Enemy has locked their shot." : "Enemy is lining up a shot…")
  }

  role() {
    const state = this.state
    if (state.status === "pending") return "pending"
    if (state.status === "finished") return "finished"

    return state.attackerSide === this.mySideValue ? "attacker" : "defender"
  }

  // --------------------------------------------------------------- actions

  async fire() {
    if (this.aimWorld === null) return

    if (await this.post("aim", { aim_x: this.aimWorld })) {
      this.state.committed.attacker = true
      this.hideAim()
      this.renderState()
    }
  }

  async confirmMove() {
    if (await this.post("move", { move_delta: this.pendingDelta })) {
      this.state.committed.defender = true
      this.ghostTarget.setAttribute("opacity", "0")
      this.renderState()
    }
  }

  async accept() {
    await this.post("accept", {})
  }

  async post(action, body) {
    this.toggle(this.errorTarget, false)

    const response = await fetch(`/battles/${this.idValue}/${action}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
      },
      body: JSON.stringify(body)
    })

    if (response.ok) return true

    const payload = await response.json().catch(() => ({}))
    this.errorTarget.textContent = payload.error ?? "Could not reach the server."
    this.toggle(this.errorTarget, true)
    return false
  }

  // ---------------------------------------------------------------- aiming

  onPointerMove(event) {
    if (!this.canAim()) return

    this.aimWorld = clamp(xToWorld(this.sceneX(event)), 0, 100)
    this.drawAim(this.aimWorld)
  }

  onPointerLeave() {
    if (this.canAim() && this.aimWorld === null) this.hideAim()
  }

  drawAim(world) {
    const from = this.muzzleFor(this.state.attackerSide, this.positionOf(this.state.attackerSide))
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

    this.fireButtonTarget.disabled = false
    this.targetOutTarget.textContent = world.toFixed(1)
    const angle = Math.atan2(from.y - control.y, control.x - from.x) * (180 / Math.PI)
    this.angleOutTarget.textContent = `${Math.abs(angle).toFixed(0)}°`
  }

  hideAim() {
    this.aimWorld = null
    this.aimArcTarget.setAttribute("opacity", "0")
    this.crosshairTarget.setAttribute("opacity", "0")
    this.aimDropTarget.setAttribute("opacity", "0")
    this.fireButtonTarget.disabled = true
  }

  controlPoint(from, to) {
    const rise = clamp(Math.abs(to.x - from.x) * 0.55, 140, 300)
    const topY = Math.min(from.y, to.y)
    return { x: (from.x + to.x) / 2, y: 2 * (topY - rise) - (from.y + to.y) / 2 }
  }

  // ---------------------------------------------------------------- moving

  selectMove(event) {
    this.pendingDelta = Number(event.currentTarget.dataset.delta)
    const landing = this.clampPosition(this.positionOf(this.mySideValue) + this.pendingDelta)

    this.moveButtonTargets.forEach((button) => {
      button.classList.toggle("is-active", button === event.currentTarget)
    })

    this.ghostTarget.setAttribute("transform", `translate(${worldToX(landing)}, ${VIEW.ground})`)
    this.ghostTarget.setAttribute("opacity", this.pendingDelta === 0 ? "0" : "0.45")
    this.positionOutTarget.textContent = landing
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
    this.ghostTarget.setAttribute("opacity", "0")
    this.setTank(defenderSide, turn.defenderFrom)
    this.setHp(defenderSide, turn.hpBefore)

    if (!this.prefersReducedMotion()) {
      const from = this.muzzleFor(turn.attackerSide, turn.attackerPosition)
      const to = { x: worldToX(turn.aimX), y: VIEW.ground }
      const control = this.controlPoint(from, to)

      // The defender rolls while the shell is still in the air — that overlap
      // is the whole game: you shoot at where you think they will be.
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
    }

    this.animating = false
    this.renderState()
  }

  async explode(point, hit) {
    this.explosionTarget.setAttribute("transform", `translate(${point.x}, ${point.y})`)
    this.sceneTarget.classList.toggle("is-shaking", hit)

    await this.tween(hit ? 520 : 340, (p) => {
      this.explosionTarget.firstElementChild.setAttribute("r", (hit ? 18 : 8) + p * (hit ? 52 : 22))
      this.explosionTarget.setAttribute("opacity", String(1 - p))
    })

    this.explosionTarget.setAttribute("opacity", "0")
    this.sceneTarget.classList.remove("is-shaking")
  }

  drainHp(side, before, after) {
    return this.tween(520, (p) => this.setHp(side, Math.round(before + (after - before) * p)))
  }

  // --------------------------------------------------------------- helpers

  canAim() {
    const state = this.state
    return !!state &&
      state.status === "active" &&
      state.attackerSide === this.mySideValue &&
      !state.committed.attacker &&
      !this.animating
  }

  syncCursor() {
    this.sceneTarget.classList.toggle("is-aimable", this.canAim())
  }

  placeTanks() {
    this.setTank("one", this.state.positions.one)
    this.setTank("two", this.state.positions.two)
  }

  setTank(side, unit) {
    const target = side === "one" ? this.tankOneTarget : this.tankTwoTarget
    target.setAttribute("transform", `translate(${worldToX(unit)}, ${VIEW.ground})`)
  }

  setHp(side, value) {
    const max = this.state.maxHp[side]
    const bar = side === "one" ? this.hpBarOneTarget : this.hpBarTwoTarget
    const text = side === "one" ? this.hpTextOneTarget : this.hpTextTwoTarget

    bar.style.width = `${clamp((value / max) * 100, 0, 100)}%`
    text.textContent = value
  }

  positionOf(side) {
    return this.state.positions[side]
  }

  nameValue(side) {
    return side === "one" ? this.nameOneValue : this.nameTwoValue
  }

  muzzleFor(side, unit) {
    const facing = side === "one" ? 1 : -1
    return { x: worldToX(unit) + facing * MUZZLE.forward, y: VIEW.ground - MUZZLE.height }
  }

  toggle(element, visible) {
    element.hidden = !visible
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
