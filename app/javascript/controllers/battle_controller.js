import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// Must mirror the geometry baked into battles/_field.html.erb.
const VIEW = { width: 1000, height: 460, margin: 46, span: 908, ground: 372 }
const MUZZLE = { forward: 32, height: 28 }
// These mirror the rules in Battle; the server re-checks everything, so they
// only exist to make the preview agree with what will actually happen.
const MIN_SEPARATION = 12
const TANK_HALF = 2.5
const MAX_MOVE = 9

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
    "scene", "tankOne", "tankTwo", "ghost", "moveRange", "aimArc", "aimDrop",
    "crosshair", "crosshairLabel", "projectile", "explosion",
    "damagePopup", "damageText",
    "hpTextOne", "hpTextTwo", "hpBarOne", "hpBarTwo", "turnNumber", "roleLabel",
    "clock", "clockValue",
    "aimPanel", "infoPanel", "movePanel", "waitPanel", "acceptPanel", "resultPanel",
    "fireButton", "targetOut", "angleOut", "positionOut",
    "waitTitle", "waitNote", "resultTitle", "resultNote", "ticker", "error"
  ]

  static values = {
    id: Number,
    mySide: String,
    nameOne: String,
    nameTwo: String,
    state: Object
  }

  connect() {
    this.animating = false
    this.submitting = false
    this.damageToken = 0
    this.aimWorld = null
    this.myAim = null
    this.myMove = null
    this.seenReplayId = 0
    this.socketEverConnected = false
    this.clockEndsAt = null
    this.clockTimer = null
    this.outOfTime = false
    this.nudgedTurn = null
    this.lastRoundNote = ""

    this.onPointerMove = this.onPointerMove.bind(this)
    this.onPointerLeave = this.onPointerLeave.bind(this)
    this.onSceneClick = this.onSceneClick.bind(this)
    this.sceneTarget.addEventListener("pointermove", this.onPointerMove)
    this.sceneTarget.addEventListener("pointerleave", this.onPointerLeave)
    this.sceneTarget.addEventListener("click", this.onSceneClick)

    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "BattleChannel", id: this.idValue },
      {
        received: (state) => this.applyState(state, false),
        // Everything broadcast while the socket was down is gone for good, so a
        // reconnected client has to ask for the current state instead of
        // trusting what is on screen. Phones make this the normal case: locking
        // the screen or switching apps drops the connection every time.
        //
        // Any connect past the first one is a reconnect, so we count them here
        // rather than trust Action Cable's `reconnected` flag: it stays false
        // when the socket is reopened from visibilitychange, which is precisely
        // the coming-back-to-the-app case. The first connect needs no resync —
        // the page render already carried the state.
        connected: () => {
          if (this.socketEverConnected) this.resync()
          this.socketEverConnected = true
        }
      }
    )

    this.applyState(this.stateValue, true)
  }

  disconnect() {
    this.sceneTarget.removeEventListener("pointermove", this.onPointerMove)
    this.sceneTarget.removeEventListener("pointerleave", this.onPointerLeave)
    this.sceneTarget.removeEventListener("click", this.onSceneClick)
    this.stopClock()
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

    // A new round wipes whatever was staged for the previous one.
    if (this.renderedTurn !== state.turnNumber) {
      this.renderedTurn = state.turnNumber
      this.myAim = null
      this.myMove = null
      this.hideAim()
    }

    // Only the page render carries `you`; broadcasts leave it out, so this
    // restores your own locked-in choice across a reload without ever telling
    // you the opponent's.
    if (state.you) {
      if (state.you.aim != null) this.myAim = state.you.aim
      if (state.you.move != null) this.myMove = state.you.move
    }

    this.startClock(state.turnEndsIn)

    this.placeTanks()
    this.setHp("one", state.hp.one)
    this.setHp("two", state.hp.two)

    this.turnNumberTarget.textContent = state.status === "pending" ? "READY?" : `TURN ${state.turnNumber}`
    this.roleLabelTarget.textContent = ROLE_LABELS[role]
    this.roleLabelTarget.className = `hud-turn-role hud-turn-role--${role}`

    this.renderPanels(role)
    this.renderTicker(role)
    this.renderMoveRange(role)

    if (this.canMove()) {
      this.previewMove(0)
    } else {
      this.ghostTarget.setAttribute("opacity", "0")
    }

    this.renderCommitted(role)
    this.syncCursor()
  }

  // Once you have committed, keep showing what you committed to — where the
  // shell is headed, or where you are about to roll.
  renderCommitted(role) {
    const state = this.state
    const locked = state.status === "active"

    this.ghostTarget.classList.toggle("is-locked", false)
    if (!locked) return

    if (role === "attacker" && state.committed.attacker && this.myAim !== null) {
      this.drawAim(this.myAim, true)
    }

    if (role === "defender" && state.committed.defender && this.myMove !== null) {
      const landing = this.clampPosition(this.positionOf(this.mySideValue) + this.myMove)
      this.placeGhost(landing)
      this.ghostTarget.setAttribute("opacity", "0.7")
      this.ghostTarget.classList.add("is-locked")
      this.positionOutTarget.textContent = landing
    }
  }

  renderPanels(role) {
    const state = this.state
    const decided = role === "attacker" ? state.committed.attacker : state.committed.defender
    // Running out of time closes the panel just like deciding does — there is
    // nothing left to choose either way.
    const committed = decided || this.outOfTime
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
      const lateTitle = role === "attacker" ? "NO SHOT" : "HOLDING STILL"

      this.waitTitleTarget.textContent = pending
        ? "WAITING FOR OPPONENT"
        : decided ? "LOCKED IN" : lateTitle

      this.waitNoteTarget.textContent = pending
        ? `${this.nameValue("two")} has not accepted the challenge yet.`
        : decided
          ? (role === "attacker"
            ? "Shot locked in. Waiting for the enemy to move…"
            : "Move locked in. Waiting for the enemy to fire…")
          : (role === "attacker"
            ? "Out of time — this round you do not fire."
            : "Out of time — this round you stay where you are.")
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

    const live = role === "attacker"
      ? (state.committed.defender ? "Enemy has committed their move." : "Enemy is deciding where to roll…")
      : (state.committed.attacker ? "Enemy has locked their shot." : "Enemy is lining up a shot…")

    this.tickerTarget.textContent = this.lastRoundNote ? `${this.lastRoundNote} ${live}` : live
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

    const aim = this.aimWorld

    if (await this.post("aim", { aim_x: aim })) {
      this.myAim = aim
      this.state.committed.attacker = true
      this.renderState()
    }
  }

  async commitMove(delta) {
    if (!this.canMove()) return

    if (await this.post("move", { move_delta: delta })) {
      this.myMove = delta
      this.state.committed.defender = true
      this.renderState()
    }
  }

  async accept() {
    await this.post("accept", {})
  }

  // ---------------------------------------------------------------- clock

  // The server sends how many seconds are left rather than when the turn ends,
  // so we anchor the countdown to the local clock and never care whether the
  // device agrees with the server about the time of day.
  startClock(secondsLeft) {
    if (secondsLeft == null) {
      this.stopClock()
      this.toggle(this.clockTarget, false)
      return
    }

    this.clockEndsAt = performance.now() + secondsLeft * 1000
    this.outOfTime = false
    this.toggle(this.clockTarget, true)
    this.tickClock()

    // Re-arming on every state update would restart the interval for nothing;
    // the anchor above is all a running one needs.
    if (!this.clockTimer) this.clockTimer = setInterval(() => this.tickClock(), 250)
  }

  stopClock() {
    if (this.clockTimer) clearInterval(this.clockTimer)
    this.clockTimer = null
    this.clockEndsAt = null
  }

  tickClock() {
    if (this.clockEndsAt === null) return

    const left = Math.max(0, (this.clockEndsAt - performance.now()) / 1000)
    this.clockValueTarget.textContent = Math.ceil(left)
    this.clockTarget.classList.toggle("is-urgent", left <= 10)

    if (left > 0) return

    // Out of time: stop taking input here as well, so a click that lands in the
    // same instant cannot be submitted against a turn that is already over.
    if (!this.outOfTime) {
      this.outOfTime = true
      this.syncCursor()
      this.renderPanels(this.role())
    }

    this.nudgeExpire()
  }

  // Tell the server the clock ran out. It checks the deadline itself, so this
  // is only a nudge — and one per turn is enough, since both players send it
  // and whoever arrives second is a no-op.
  async nudgeExpire() {
    const turn = this.state?.turnNumber
    if (this.nudgedTurn === turn) return

    this.nudgedTurn = turn
    try {
      await fetch(`/battles/${this.idValue}/expire`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        }
      })
    } catch {
      // Offline. The opponent's browser nudges too, and coming back reloads
      // state anyway, so there is nothing to retry here.
    }
  }

  // Refetch the state the socket could not deliver. It is applied as a normal
  // update rather than an initial one, so a round that resolved while we were
  // away still plays its animation — seenReplayId keeps an already-watched one
  // from playing twice.
  async resync() {
    try {
      const response = await fetch(`/battles/${this.idValue}/state`, {
        headers: { "Accept": "application/json" }
      })
      if (response.ok) this.applyState(await response.json(), false)
    } catch {
      // Dropped again mid-request; the next `connected` will retry.
    }
  }

  async post(action, body) {
    // Acting on a click means a double click must not send the move twice.
    if (this.submitting) return false

    this.submitting = true
    this.toggle(this.errorTarget, false)

    try {
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
    } finally {
      this.submitting = false
    }
  }

  // ---------------------------------------------------------------- aiming

  onPointerMove(event) {
    if (this.canAim()) {
      this.aimWorld = clamp(xToWorld(this.sceneX(event)), 0, 100)
      this.drawAim(this.aimWorld)
    } else if (this.canMove()) {
      // Hovering only previews; the choice is pinned on click.
      this.previewMove(this.deltaAt(event))
    }
  }

  onPointerLeave() {
    if (this.canMove()) this.previewMove(0)
  }

  onSceneClick(event) {
    if (this.canAim()) {
      this.fire()
    } else if (this.canMove()) {
      this.commitMove(this.deltaAt(event))
    }
  }

  drawAim(world, locked = false) {
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

    this.aimArcTarget.classList.toggle("is-locked", locked)
    this.crosshairTarget.classList.toggle("is-locked", locked)
    if (locked) return

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
    this.aimArcTarget.classList.remove("is-locked")
    this.crosshairTarget.classList.remove("is-locked")
    this.fireButtonTarget.disabled = true
  }

  controlPoint(from, to) {
    const rise = clamp(Math.abs(to.x - from.x) * 0.55, 140, 300)
    const topY = Math.min(from.y, to.y)
    return { x: (from.x + to.x) / 2, y: 2 * (topY - rise) - (from.y + to.y) / 2 }
  }

  // ---------------------------------------------------------------- moving

  selectMove(event) {
    this.commitMove(Number(event.currentTarget.dataset.delta))
  }

  // How far a click at this point would move us, capped at the roll limit.
  deltaAt(event) {
    const world = clamp(xToWorld(this.sceneX(event)), 0, 100)
    const raw = Math.round(world - this.positionOf(this.mySideValue))

    return clamp(raw, -MAX_MOVE, MAX_MOVE)
  }

  previewMove(delta) {
    const from = this.positionOf(this.mySideValue)
    const landing = this.clampPosition(from + delta)

    this.placeGhost(landing)
    this.ghostTarget.setAttribute("opacity", landing === from ? "0" : "0.45")
    this.positionOutTarget.textContent = landing
  }

  // Mirrored for the right-hand player so the ghost faces the same way as the
  // tank it stands in for.
  placeGhost(landing) {
    const facing = this.mySideValue === "one" ? 1 : -1
    this.ghostTarget.setAttribute(
      "transform",
      `translate(${worldToX(landing)}, ${VIEW.ground}) scale(${facing}, 1)`
    )
  }

  // Everywhere the defender could still end up. Shown to the attacker as well:
  // positions and the roll limit are both public, so it gives nothing away —
  // it just makes the guess you are making legible.
  renderMoveRange(role) {
    const state = this.state
    const defenderSide = state.attackerSide === "one" ? "two" : "one"
    const visible = state.status === "active" &&
      (role === "attacker" || !state.committed.defender)

    if (!visible) {
      this.moveRangeTarget.setAttribute("opacity", "0")
      return
    }

    const from = this.positionOf(defenderSide)
    const left = worldToX(this.clampPosition(from - MAX_MOVE, defenderSide))
    const right = worldToX(this.clampPosition(from + MAX_MOVE, defenderSide))

    this.moveRangeTarget.setAttribute("x", left)
    this.moveRangeTarget.setAttribute("width", Math.max(0, right - left))
    this.moveRangeTarget.setAttribute("opacity", "1")
  }

  clampPosition(position, moverSide = this.mySideValue) {
    const opponent = this.positionOf(moverSide === "one" ? "two" : "one")
    const kept = position < opponent
      ? Math.min(position, opponent - MIN_SEPARATION)
      : Math.max(position, opponent + MIN_SEPARATION)

    return Math.round(clamp(kept, TANK_HALF, 100 - TANK_HALF))
  }

  // --------------------------------------------------------------- replay

  async playReplay(turn) {
    const defenderSide = turn.attackerSide === "one" ? "two" : "one"
    // No aim point means the attacker's clock ran out: the tank still rolls,
    // but nothing is fired at it.
    const fired = turn.aimX != null

    // Carried into the next turn's ticker — this is the only place a player
    // learns their opponent ran the clock down. Reset on every replay, so a
    // normal round clears it.
    const notes = []
    if (turn.attackerTimedOut) notes.push(`${this.nameValue(turn.attackerSide)} ran out of time and never fired.`)
    if (turn.defenderTimedOut) notes.push(`${this.nameValue(defenderSide)} ran out of time and held still.`)
    this.lastRoundNote = notes.join(" ")

    this.animating = true
    this.stopClock()
    this.hideAim()
    this.ghostTarget.setAttribute("opacity", "0")
    this.setTank(defenderSide, turn.defenderFrom)
    this.setHp(defenderSide, turn.hpBefore)

    if (!this.prefersReducedMotion()) {
      // The defender rolls while the shell is still in the air — that overlap
      // is the whole game: you shoot at where you think they will be.
      const rolling = this.tween(700, (p) => {
        const eased = easeInOut(p)
        this.setTank(defenderSide, turn.defenderFrom + (turn.defenderTo - turn.defenderFrom) * eased)
      })

      if (fired) {
        const from = this.muzzleFor(turn.attackerSide, turn.attackerPosition)
        const to = { x: worldToX(turn.aimX), y: VIEW.ground }
        const control = this.controlPoint(from, to)

        this.projectileTarget.setAttribute("opacity", "1")
        await this.tween(1100, (p) => {
          const point = quadPoint(from, control, to, p)
          this.projectileTarget.setAttribute("cx", point.x)
          this.projectileTarget.setAttribute("cy", point.y)
        })
        this.projectileTarget.setAttribute("opacity", "0")
        await rolling
        await this.explode(to, turn.hit)
      } else {
        await rolling
      }

      if (turn.damage > 0) {
        // Deliberately not awaited: the number lingers for three seconds while
        // play carries on.
        this.showDamage(turn.defenderTo, turn.damage)
        await this.drainHp(defenderSide, turn.hpBefore, turn.hpAfter)
      }
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

  // Floats the damage above the tank that took it and clears after 3s. A newer
  // hit cancels an older popup rather than fighting it for the same element.
  async showDamage(unit, amount) {
    const token = ++this.damageToken
    const x = worldToX(unit)
    const top = VIEW.ground - 56
    const alive = () => this.damageToken === token

    this.damageTextTarget.textContent = `-${amount}`
    this.damagePopupTarget.setAttribute("transform", `translate(${x}, ${top})`)
    this.damagePopupTarget.setAttribute("opacity", "1")

    await this.tween(600, (p) => {
      if (!alive()) return
      this.damagePopupTarget.setAttribute("transform", `translate(${x}, ${top - p * 30})`)
    })
    if (!alive()) return

    await new Promise((resolve) => setTimeout(resolve, 1900))
    if (!alive()) return

    await this.tween(500, (p) => {
      if (alive()) this.damagePopupTarget.setAttribute("opacity", String(1 - p))
    })
    if (alive()) this.damagePopupTarget.setAttribute("opacity", "0")
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
      !this.animating &&
      !this.outOfTime
  }

  canMove() {
    const state = this.state
    return !!state &&
      state.status === "active" &&
      state.attackerSide !== this.mySideValue &&
      !state.committed.defender &&
      !this.animating &&
      !this.outOfTime
  }

  syncCursor() {
    this.sceneTarget.classList.toggle("is-aimable", this.canAim())
    this.sceneTarget.classList.toggle("is-movable", this.canMove())
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
