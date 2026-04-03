using Oxygen
using HTTP
using JSON3
using Dates
using UUIDs

push!(LOAD_PATH, "src")
using Ingest
using Model
using BanditCore
using Storage

const DB = Storage.init_storage()

@repeat 3600 "news_update" () -> Ingest.update_news!()


@post "/interact" function (req::HTTP.Request)
	data = JSON3.read(req.body)

	user_id = string(get(data, :user_id, ""))
	article_id = string(get(data, :article_id, ""))
	action = string(get(data, :action, "click")) # "click" oder "dismiss"

	if isempty(user_id) || isempty(article_id)
		return res(400, Dict("error" => "Missing parameters"))
	end

	# 1. Profil laden
	profile = Storage.load_user(DB, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	# 2. Artikel aus dem Pool holen
	article = lock(Ingest.POOL_LOCK) do
		get(Ingest.ARTICLE_POOL, article_id, nothing)
	end

	if article === nothing
		return res(404, Dict("error" => "Article expired or not found"))
	end

	# 3. Belohnung/Bestrafung berechnen
	# Wir übergeben die Aktion an BanditCore
	reward = 0.0f0
	if action == "click"
		reward = BanditCore.robust_reward(profile.last_interaction, now(); τ = 3.0)
	elseif action == "dismiss"
		reward = -0.5f0 # Fixer negativer Push
	end

	# 4. Mathematisches Update
	article_emb = article.embedding[1:128]
	BanditCore.update_factor!(profile, article_emb, reward)

	# 5. Persistence: Profil speichern UND Artikel als "gesehen" markieren
	Storage.save_user(DB, profile)
	Storage.mark_article_seen(DB, user_id, article_id)

	return Dict(
		"status" => "processed",
		"action" => action,
		"reward" => reward,
		"bot_filtered" => (action == "click" && reward == 0.0),
	)
end

@post "/user" function (req::HTTP.Request)
	data = JSON3.read(req.body)
	user_id = haskey(data, :user_id) ? string(data.user_id) : string(uuid4())

	existing = Storage.load_user(DB, user_id)
	if existing !== nothing
		return Dict("message" => "User recovered", "user_id" => user_id)
	end

	new_profile = BanditCore.UserProfile(user_id, 128)
	Storage.save_user(DB, new_profile)

	return Dict("message" => "User initialized", "user_id" => user_id)
end

@get "/recommend/{user_id}" function (req::HTTP.Request, user_id::String)
	# 1. Profil und Historie laden
	profile = Storage.load_user(DB, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	# NEU: Wir holen uns die IDs der Artikel, die der User schon gesehen/geklickt hat
	seen_ids = Storage.get_seen_article_ids(DB, user_id)

	# 2. Verfügbare Artikel aus dem Pool holen (Threadsicher)
	all_articles = lock(Ingest.POOL_LOCK) do
		collect(values(Ingest.ARTICLE_POOL))
	end

	if isempty(all_articles)
		return Dict("message" => "Pool empty", "recommendations" => [])
	end

	# 3. FILTERING: Nur Artikel, die noch nicht in seen_ids sind
	available_articles = filter(art -> !(art.id in seen_ids), all_articles)

	if isempty(available_articles)
		return Dict("message" => "All articles seen", "recommendations" => [])
	end

	# 4. UCB-Empfehlungen berechnen
	recommendations = BanditCore.get_recommendations(profile, available_articles, 0.1f0)

	# 5. Top 5 für das Frontend aufbereiten (Deduplizierung über Titel)
	top_recs = []
	seen_titles = Set{String}()

	for art in recommendations
		if !(art.title in seen_titles)
			push!(top_recs, Dict(
				"id" => art.id,
				"title" => art.title,
				"url" => art.url,
				"image_url" => art.image_url,
				"timestamp" => art.timestamp,
			))
			push!(seen_titles, art.title)
		end
		length(top_recs) >= 5 && break
	end

	return Dict("user" => user_id, "recommendations" => top_recs)
end

@get "/status" function (req::HTTP.Request)
	psize = lock(Ingest.POOL_LOCK) do
		length(Ingest.ARTICLE_POOL)
	end
	return Dict(
		"status" => "online",
		"pool_size" => psize,
		"threads" => Threads.nthreads(),
	)
end

# Startup
println("Pre-loading News Feed...")
Ingest.update_news!()

println("Kairos Engine v2 (Event-Driven) starting on port 8080...")
serveparallel(port = 8080)