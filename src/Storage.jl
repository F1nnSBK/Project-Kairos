module Storage

using SQLite, Serialization, DBInterface, Dates

import BanditCore.UserProfile

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

	SQLite.execute(
		db,
		"""
	CREATE TABLE IF NOT EXISTS user_seen (
		user_id TEXT,
		article_id TEXT,
		seen_at DATETIME,
		PRIMARY KEY (user_id, article_id)
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

function load_user(db::SQLite.DB, user_id::String)
	result = DBInterface.execute(db, "SELECT state FROM users WHERE user_id = ?", [user_id])

	for row in result
		try
			buf = IOBuffer(row.state)
			return deserialize(buf)
		catch e
			@warn "Outdated profile format for user $user_id. Resetting..."
			SQLite.execute(db, "DELETE FROM users WHERE user_id = ?", [user_id])
			return nothing
		end
	end
	return nothing
end

function mark_article_seen(db::SQLite.DB, user_id::String, article_id::String)
	try
		SQLite.execute(db,
			"INSERT OR IGNORE INTO user_seen (user_id, article_id, seen_at) VALUES (?, ?, DATETIME('now'))",
			[user_id, article_id],
		)
	catch e
		@error "Error marking article $article_id as seen: $e"
	end
end

function get_seen_article_ids(db::SQLite.DB, user_id::String)
	result = DBInterface.execute(db,
		"SELECT article_id FROM user_seen WHERE user_id = ?",
		[user_id],
	)

	ids = Set{String}()
	for row in result
		push!(ids, row.article_id)
	end
	return ids
end

function cleanup_history!(db::SQLite.DB, days::Int = 30)
	SQLite.execute(db,
		"DELETE FROM user_seen WHERE seen_at < DATETIME('now', '-$days days')",
	)
end

end
