class BattleTurnsController < ApplicationController
  before_action :require_character!
  before_action :set_battle

  def aim
    commit { @battle.submit_aim!(current_character, params.require(:aim_x)) }
  end

  def move
    commit { @battle.submit_move!(current_character, params.require(:move_delta)) }
  end

  private

  def set_battle
    @battle = Battle.find(params[:id])
  end

  def commit
    yield
    redirect_to battle_path(@battle)
  rescue RuntimeError => e
    redirect_to battle_path(@battle), alert: e.message
  end
end
