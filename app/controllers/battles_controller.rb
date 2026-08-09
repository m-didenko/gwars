class BattlesController < ApplicationController
  before_action :require_character!
  before_action :set_battle, only: [:show, :accept]

  def index
    @opponents = Character.where.not(id: current_character&.id).order(:name)
    @battles = Battle.where(player_one: current_character).or(Battle.where(player_two: current_character))
                      .order(created_at: :desc)
  end

  def create
    opponent = Character.find(params[:opponent_id])
    @battle = Battle.new(player_one: current_character, player_two: opponent, status: :pending)

    if @battle.save
      redirect_to battle_path(@battle), notice: "Challenge sent to #{opponent.name}"
    else
      redirect_to battles_path, alert: @battle.errors.full_messages.to_sentence
    end
  end

  def show
    redirect_to battles_path, alert: "Not your battle" and return unless @battle.participant?(current_character)

    @role = @battle.role_for(current_character)
    @turn = @battle.current_turn
    @replay = @battle.last_resolved_turn&.animation_payload(@battle)
  end

  def accept
    redirect_to battles_path, alert: "Not your battle" and return unless @battle.participant?(current_character)

    @battle.accept!
    redirect_to battle_path(@battle), notice: "Battle started!"
  rescue RuntimeError => e
    redirect_to battle_path(@battle), alert: e.message
  end

  private

  def set_battle
    @battle = Battle.find(params[:id])
  end
end
