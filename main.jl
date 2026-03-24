using Oxygen
using HTTP
using JSON3
using Dates

push!(LOAD_PATH, "src")
using Ingest
using Model
using BanditCore
using Storage

const DB = Storage.init_storage()

@repeat 3600 "news_update" () -> Ingest.update_news!()

@post "/click" function (req::HTTP.Request)
	data = JSON3.read(req.body)

	user_id = string(get(data, :user_id, ""))
	article_id = string(get(data, :article_id, ""))

	if isempty(user_id) || isempty(article_id)
		return res(400, Dict("error" => "Missing user_id or article_id"))
	end

	profile = Storage.load_user(DB, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	article = lock(Ingest.POOL_LOCK) do
		get(Ingest.ARTICLE_POOL, article_id, nothing)
	end

	if article === nothing
		return res(404, Dict("error" => "Article not found in pool"))
	end

	reward = BanditCore.robust_reward(profile.last_interaction, now(); τ = 3.0)

	article_emb = article.embedding[1:128]
	BanditCore.scfd_update!(profile, article_emb, reward)

	Storage.save_user(DB, profile)

	return Dict(
		"status" => "updated",
		"reward_applied" => reward,
		"bot_filtered" => reward == 0.0,
	)
end

@post "/user" function (req::HTTP.Request)
	data = JSON3.read(req.body)
	user_id = haskey(data, :user_id) ? string(data.user_id) : string(uuid4())

	existing = Storage.load_user(DB, user_id)
	if existing !== nothing
		return Dict("message" => "User already exists", "user_id" => user_id)
	end

	new_profile = BanditCore.UserProfile(user_id, 128)
	Storage.save_user(DB, new_profile)

	return Dict(
		"message" => "User initialized",
		"user_id" => user_id,
		"status" => "ready",
	)
end

@get "/status" function (req::HTTP.Request)
	psize = lock(Ingest.POOL_LOCK) do
		length(Ingest.ARTICLE_POOL)
	end
	return Dict(
		"status" => "running",
		"pool_size" => psize,
		"last_update" => now(),
		"threads" => Threads.nthreads(),
	)
end

@get "/news" function (req::HTTP.Request)
	return lock(Ingest.POOL_LOCK) do
		collect(values(Ingest.ARTICLE_POOL))
	end
end

@get "/recommend/{user_id}" function (req::HTTP.Request, user_id::String)
	profile = Storage.load_user(DB, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	articles = lock(Ingest.POOL_LOCK) do
		collect(values(Ingest.ARTICLE_POOL))
	end

	if isempty(articles)
		return Dict("message" => "Article pool is empty.")
	end

	recommendations = BanditCore.get_recommendations(profile, articles, 0.1f0)

	top_recs = []
	seen_titles = Set{String}()

	for art in recommendations
		if !(art.title in seen_titles)
			push!(top_recs, Dict(
				"id" => art.id,
				"title" => art.title,
				"url" => art.url,
				"timestamp" => art.timestamp,
			))
			push!(seen_titles, art.title)
		end
		length(top_recs) >= 5 && break
	end

	return Dict("user" => user_id, "recommendations" => top_recs)
end

println("Initial news ingest...")
Ingest.update_news!()

println("Kairos Engine starting on port 8080...")
serveparallel(port = 8080)
