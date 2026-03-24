module Ingest

using HTTP, JSON3, Dates, LinearAlgebra
using Model

export Article, ARTICLE_POOL, update_news!, POOL_LOCK

struct Article
	id::String
	title::String
	url::String
	timestamp::DateTime
	embedding::Vector{Float32}
end

const ARTICLE_POOL = Dict{String, Article}()
const POOL_LOCK = ReentrantLock()

function update_news!()
	println("$(now()): Polling Tagesschau API...")

	headers = [
		"User-Agent" => "Kairos-News-Engine/1.0",
		"Accept" => "application/json",
	]

	try
		url = "https://www.tagesschau.de/api2u/news/"
		response = HTTP.get(url, headers)
		data = JSON3.read(response.body)

		new_count = 0
		lock(POOL_LOCK) do
			for item in data.news
				id = get(item, :sophoraId, "")
				title = get(item, :title, "")
				topline = get(item, :topline, "")
				first_sentence = get(item, :firstSentence, "")
				link = get(item, :details, "")

				embedding_input = "$topline: $title. $first_sentence"

				if !isempty(id) && !haskey(ARTICLE_POOL, id)
					# Generate 768-dim embedding via Model.jl
					emb = get_mrl_embedding(embedding_input, 768)

					ARTICLE_POOL[id] = Article(id, title, link, now(), emb)
					new_count += 1
				end
			end

			# Remove articles older than 24 hours
			cleanup_limit = now() - Hour(24)
			filter!(p -> p.second.timestamp > cleanup_limit, ARTICLE_POOL)

		end
		println("$(now()): Ingest complete. $new_count new articles. Pool size: $(length(ARTICLE_POOL))")
	catch e
		@error "News ingest failed" exception=e
	end
end

end
