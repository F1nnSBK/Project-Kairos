module Storage

using SQLite
using Serialization
using DBInterface

import ..BanditCore: UserProfile

const DB_PATH = "data/kairos.db"

function init_storage()
	mkpath("data")
	db = SQLite.DB(DB_PATH)
	SQLite.execute(
		db,
		"""
	CREATE TABLE IF NOT EXISTS users (
		user_id TEXT PRIMARY KEY,
		state BLOB,
		updated_at DATETIME
	)
""",
	)
	return db
end

function save_user(db, profile::UserProfile)
	buf = IOBuffer()
	serialize(buf, profile)
	data = take!(buf)

	SQLite.execute(db,
		"INSERT OR REPLACE INTO users (user_id, state, updated_at) VALUES (?, ?, DATETIME('now'))",
		[profile.user_id, data],
	)
end

function load_user(db, user_id::String)
	result = DBInterface.execute(db, "SELECT state FROM users WHERE user_id = ?", [user_id])

	for row in result
		return deserialize(IOBuffer(row.state))::UserProfile
	end
	return nothing
end

end
