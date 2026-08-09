class ApplicationController < ActionController::Base
  before_action :authenticate_user!, unless: :devise_controller?

  private

  def current_character
    current_user&.character
  end
  helper_method :current_character

  def require_character!
    redirect_to new_character_path, alert: "Create a character first" unless current_character
  end
end
