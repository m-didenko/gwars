class BattlesController < ApplicationController
  before_action :require_character!
  before_action :set_battle, only: [:show, :state, :log]

  def index
    @battles = Battle.where(player_one: current_character).or(Battle.where(player_two: current_character))
                      .order(created_at: :desc)
  end

  def show
    redirect_to battles_path, alert: "Not your battle" and return unless @battle.participant?(current_character)

    # Coming back to a battle nobody was watching: settle the turn whose clock
    # ran out while both browsers were gone, so the page never opens on a
    # countdown that expired minutes ago.
    @battle.resolve_if_expired!
  end

  # Asked for by the client after its websocket reconnects: a dropped socket
  # means missed broadcasts, and the browser would otherwise keep showing the
  # board as it was when the connection died.
  #
  # Like the page render — and unlike the broadcast — this is per-viewer, so it
  # carries the `you` section with that player's own committed choice. Which is
  # exactly why it must stay behind the participant check.
  def state
    return head :forbidden unless @battle.participant?(current_character)

    @battle.resolve_if_expired!
    render json: @battle.state_payload(current_character)
  end

  # The broadcast state only ever carries the last few rounds — a resolved
  # turn has no secrets, but there is no reason to ship a battle's whole
  # history on every reconnect. This is the "show me the rest" the log panel
  # asks for on demand, behind the same participant check as `state`.
  def log
    return head :forbidden unless @battle.participant?(current_character)

    turns = @battle.battle_turns.where.not(resolved_at: nil).order(turn_number: :desc)
    render json: { turns: turns.map { |t| t.animation_payload(@battle) } }
  end

  private

  def set_battle
    @battle = Battle.find(params[:id])
  end
end
