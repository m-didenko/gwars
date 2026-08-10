class CreateQueueEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :queue_entries do |t|
      # One place in line per commander; the unique index is what actually
      # stops a double click from queueing someone twice.
      t.references :character, null: false, index: { unique: true }

      t.timestamps
    end

    # Pairing always takes the two who have waited longest.
    add_index :queue_entries, :created_at
  end
end
