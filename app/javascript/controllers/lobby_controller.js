import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// The lobby queue. The button posts, the channel pushes, and a match takes the
// player into the duel without anyone reloading anything.
export default class extends Controller {
  static targets = ["status", "button"]
  static values = { state: Object }

  connect() {
    this.busy = false
    this.entering = false
    this.state = this.stateValue

    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "LobbyChannel" },
      { received: (message) => this.receive(message) }
    )

    this.render()
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
  }

  receive(message) {
    if (message.type === "queue") {
      this.state = { ...this.state, waiting: message.waiting }
      this.render()
    }

    if (message.type === "matched") this.enter(message.battleId)
  }

  async toggle() {
    // A second click while the first is in flight would queue and unqueue in
    // the same breath.
    if (this.busy || this.entering) return

    this.busy = true
    this.buttonTarget.disabled = true

    try {
      const response = await fetch(this.state.queued ? "/lobby/leave" : "/lobby/join", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        }
      })

      if (!response.ok) {
        this.statusTarget.textContent = "Could not reach the lobby. Try again."
        return
      }

      this.state = await response.json()
      this.render()

      // Matched by our own join: the channel says so too, but this covers the
      // player whose socket happens to be down.
      if (this.state.battleId) this.enter(this.state.battleId)
    } catch {
      this.statusTarget.textContent = "Could not reach the lobby. Try again."
    } finally {
      this.busy = false
      this.buttonTarget.disabled = this.entering
    }
  }

  // Both the channel and the join response can announce the same match, so the
  // first one through wins and the rest are ignored.
  enter(battleId) {
    if (this.entering) return

    this.entering = true
    this.buttonTarget.disabled = true
    this.statusTarget.textContent = "Opponent found — dropping you in…"
    window.location.href = `/battles/${battleId}`
  }

  render() {
    if (this.entering) return

    const waiting = this.state.waiting ?? 0
    const others = this.state.queued ? waiting - 1 : waiting

    this.buttonTarget.textContent = this.state.queued ? "LEAVE THE QUEUE" : "JOIN THE QUEUE"
    this.buttonTarget.classList.toggle("btn--primary", !this.state.queued)
    this.element.classList.toggle("is-queued", this.state.queued)

    this.statusTarget.textContent = this.state.queued
      ? (others > 0
        ? `In the queue. ${this.count(others)} also waiting — pairing now…`
        : "In the queue. Waiting for another commander…")
      : (waiting > 0
        ? `${this.count(waiting)} waiting. Join and the duel starts at once.`
        : "Nobody is waiting yet. Be the first.")
  }

  count(n) {
    return n === 1 ? "1 commander" : `${n} commanders`
  }
}
