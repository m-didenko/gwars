import { Controller } from "@hotwired/stimulus"

// Mirrors Character::LIFE_REGEN_PER_MINUTE / BATTLE_READY_LIFE. The server is
// the only thing that actually enforces the battle-ready gate — joining the
// lobby or sending a challenge re-checks it independently — so nothing here
// needs to be exact to the second. It only has to track the same regen curve
// closely enough that the bar filling in doesn't look wrong.
const LIFE_REGEN_PER_MINUTE = 5
const BATTLE_READY_LIFE = 90

export default class extends Controller {
  static targets = ["lifeText", "lifeBar", "countdown", "readyNote"]
  static values = { life: Number, maxHp: Number }

  connect() {
    this.baseLife = this.lifeValue
    this.startedAt = performance.now()

    this.tick()
    if (this.baseLife < this.maxHpValue) this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  tick() {
    const elapsedMinutes = (performance.now() - this.startedAt) / 60000
    const life = Math.min(this.maxHpValue, this.baseLife + Math.floor(elapsedMinutes * LIFE_REGEN_PER_MINUTE))

    if (this.hasLifeTextTarget) this.lifeTextTarget.textContent = life
    if (this.hasLifeBarTarget) this.lifeBarTarget.style.width = `${(100 * life / this.maxHpValue).toFixed(1)}%`

    if (life >= BATTLE_READY_LIFE) {
      if (this.hasReadyNoteTarget) this.readyNoteTarget.textContent = "Ready for battle."
    } else if (this.hasCountdownTarget) {
      const secondsToReady = ((BATTLE_READY_LIFE - this.baseLife) / LIFE_REGEN_PER_MINUTE) * 60 - elapsedMinutes * 60
      this.countdownTarget.textContent = this.formatDuration(Math.max(0, Math.round(secondsToReady)))
    }

    if (life >= this.maxHpValue && this.timer) clearInterval(this.timer)
  }

  formatDuration(totalSeconds) {
    const minutes = Math.floor(totalSeconds / 60)
    const seconds = totalSeconds % 60
    return `${minutes}:${String(seconds).padStart(2, "0")}`
  }
}
