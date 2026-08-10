class BattleTurnsController < ApplicationController
  before_action :require_character!
  before_action :set_battle

  # Both actions answer with no content: the resulting state reaches every
  # browser over BattleChannel, so there is nothing to re-render here.
  def aim
    commit { @battle.submit_aim!(current_character, params.require(:aim_x)) }
  end

  def move
    commit { @battle.submit_move!(current_character, params.require(:move_delta)) }
  end

  def accept
    commit { @battle.accept! }
  end

  # A browser whose countdown hit zero. It only asks; the model decides, so
  # nothing here trusts the client about what time it is.
  def expire
    commit { @battle.resolve_if_expired! }
  end

  private

  def set_battle
    @battle = Battle.find(params[:id])
    head :forbidden unless @battle.participant?(current_character)
  end

  def commit
    yield
    head :no_content
  rescue RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
