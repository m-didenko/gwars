# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_08_10_185556) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "battle_turns", force: :cascade do |t|
    t.bigint "battle_id", null: false
    t.integer "turn_number", null: false
    t.integer "attacker_id", null: false
    t.integer "defender_id", null: false
    t.integer "attacker_position", null: false
    t.decimal "aim_x", precision: 6, scale: 2
    t.integer "move_delta"
    t.integer "defender_position_before"
    t.integer "defender_position_after"
    t.decimal "distance", precision: 6, scale: 2
    t.boolean "hit"
    t.integer "damage"
    t.integer "defender_hp_before"
    t.integer "defender_hp_after"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deadline_at"
    t.boolean "attacker_timed_out", default: false, null: false
    t.boolean "defender_timed_out", default: false, null: false
    t.index ["battle_id", "turn_number"], name: "index_battle_turns_on_battle_id_and_turn_number", unique: true
    t.index ["battle_id"], name: "index_battle_turns_on_battle_id"
  end

  create_table "battles", force: :cascade do |t|
    t.integer "player_one_id"
    t.integer "player_two_id"
    t.integer "winner_id"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "player_one_hp"
    t.integer "player_two_hp"
    t.integer "player_one_position"
    t.integer "player_two_position"
    t.integer "attacker_id"
    t.integer "turn_number", default: 0, null: false
    t.integer "player_one_miss_streak", default: 0, null: false
    t.integer "player_two_miss_streak", default: 0, null: false
    t.index ["player_one_id"], name: "index_battles_on_player_one_id"
    t.index ["player_two_id"], name: "index_battles_on_player_two_id"
  end

  create_table "characters", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name"
    t.integer "max_hp", default: 100, null: false
    t.integer "attack", default: 10, null: false
    t.integer "defense", default: 2, null: false
    t.integer "gold", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "level", default: 1, null: false
    t.integer "experience", default: 0, null: false
    t.integer "life", default: 100, null: false
    t.datetime "life_replenished_at"
    t.index ["user_id"], name: "index_characters_on_user_id"
  end

  create_table "queue_entries", force: :cascade do |t|
    t.bigint "character_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["character_id"], name: "index_queue_entries_on_character_id", unique: true
    t.index ["created_at"], name: "index_queue_entries_on_created_at"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "battle_turns", "battles"
  add_foreign_key "characters", "users"
end
