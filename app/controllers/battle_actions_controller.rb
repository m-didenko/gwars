class BattleActionsController < ApplicationController
  before_action :require_character!

  def create
    battle = Battle.find(params[:battle_id])

    begin
      battle.attack!(current_character)
    rescue RuntimeError => e
      redirect_to battle_path(battle), alert: e.message and return
    end

    redirect_to battle_path(battle)
  end
end
