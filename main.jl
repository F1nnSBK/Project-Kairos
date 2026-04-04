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
	action = string(get(data, :action, "click"))

	if isempty(user_id) || isempty(article_id)
		return res(400, Dict("error" => "Missing parameters"))
	end

	profile = Storage.load_user(DB, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	article = lock(Ingest.POOL_LOCK) do
		get(Ingest.ARTICLE_POOL, article_id, nothing)
	end

	if article === nothing
		return res(404, Dict("error" => "Article expired or not found"))
	end


	reward = 0.0f0
	if action == "click"
		raw_reward = BanditCore.robust_reward(profile.last_interaction, now(); τ = 3.0)
		reward = raw_reward > 0 ? 2.0f0 : 0.0f0
	elseif action == "dismiss"
		reward = -0.05f0
	end

	article_emb = article.embedding[1:128]
	BanditCore.update_factor!(profile, article_emb, reward)

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
	interests = get(data, :interests, [])

	Ingest.prime_user_profile!(DB, user_id, interests)

	short_id = length(user_id) >= 8 ? user_id[1:8] : user_id
	@info "User synchronized" id=short_id clusters=interests

	return Dict(
		"message" => "Neural identity synchronized",
		"user_id" => user_id,
		"status" => isempty(interests) ? "initialized" : "aligned",
	)
end

@get "/recommend/{user_id}" function (req::HTTP.Request, user_id::String)
	profile = Storage.load_user(DB, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	seen_ids = Storage.get_seen_article_ids(DB, user_id)

	all_articles = lock(Ingest.POOL_LOCK) do
		collect(values(Ingest.ARTICLE_POOL))
	end

	if isempty(all_articles)
		return Dict("message" => "Pool empty", "recommendations" => [])
	end

	available_articles = filter(art -> !(art.id in seen_ids), all_articles)



	if isempty(available_articles)
		return Dict("message" => "All articles seen", "recommendations" => [])
	end

	α_demo = 0.02f0
	scored_recs = BanditCore.get_recommendations(profile, available_articles, α_demo)

	sorted_recs = sort(scored_recs, by = x -> x.mu, rev = true)

	top_recs = []
	seen_titles = Set{String}()

	for item in sorted_recs
		art = item.article

		if !(art.title in seen_titles)
			println("Recommended: ", art.title, " (μ=$(round(item.mu, digits = 3)), σ=$(round(item.sigma, digits = 3)))")
			match_pct = round(Int, clamp(item.mu * 100, 0, 100))

			push!(
				top_recs,
				Dict(
					"id" => art.id,
					"title" => art.title,
					"url" => art.url,
					"image_url" => art.image_url,
					"timestamp" => art.timestamp,
					"metadata" => Dict(
						"match_pct" => match_pct,
						"confidence" => round(item.sigma, digits = 3),
						"is_discovery" => item.mu < (0.02f0 * item.sigma),
					),
				),
			)
			push!(seen_titles, art.title)
		end
		length(top_recs) >= 6 && break
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

@get "/health" function (req::HTTP.Request)
	return Dict("status" => "ok")
end


println("Kairos Engine v2: Starting initialization...")

try
	Model.get_session()
	Model.get_tokenizer()
	println("✅ Neural Core warm and ready.")
catch e
	@error "FATAL: Initialization failed" exception=e
	exit(1)
end

@async begin
	try
		sleep(5)
		Ingest.update_news!()
		println("✅ Background: News updated.")
	catch e
		@error "Background news update failed"
	end
end

println("Kairos Engine v2: Listening on 0.0.0.0:8080")
serve(host = "0.0.0.0", port = 8080)
