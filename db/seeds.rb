# Seeds two demo players so a PvP battle can be tried out immediately.
#
#   bin/rails db:seed
#
# Login: player1@example.com / password123
#        player2@example.com / password123

players = [
  { email: "player1@example.com", character_name: "Al Capone" },
  { email: "player2@example.com", character_name: "Lucky Luciano" }
]

players.each do |data|
  user = User.find_or_create_by!(email: data[:email]) do |u|
    u.password = "password123"
    u.password_confirmation = "password123"
  end

  user.create_character!(name: data[:character_name]) unless user.character

  puts "Seeded #{user.email} as #{user.character.name}"
end
