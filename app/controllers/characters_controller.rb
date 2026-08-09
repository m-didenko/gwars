class CharactersController < ApplicationController
  def new
    redirect_to root_path, notice: "You already have a character" and return if current_character

    @character = Character.new
  end

  def create
    @character = current_user.build_character(character_params)

    if @character.save
      redirect_to root_path, notice: "Character created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @character = current_character || redirect_to(new_character_path)
  end

  private

  def character_params
    params.require(:character).permit(:name)
  end
end
