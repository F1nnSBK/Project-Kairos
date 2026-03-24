using Oxygen
using HTTP
using JSON3
using Dates

push!(LOAD_PATH, "src")
using Ingest
using Model

# --- Background Tasks ---
@repeat 3600 "news_update" () -> Ingest.update_news!()

# --- API ENDPOINTS ---

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
	articles = lock(Ingest.POOL_LOCK) do
		collect(values(Ingest.ARTICLE_POOL))
	end

	if isempty(articles)
		return Dict("message" => "Pool is empty, wait for ingest.")
	end

	sort!(articles, by = a -> a.timestamp, rev = true)

	return Dict(
		"user" => user_id,
		"recommendations" => articles[1:min(3, length(articles))],
	)
end

println("Initial News-Ingest...")
Ingest.update_news!()

println("Kairos Engine starting on Port 8080...")
serveparallel(port = 8080)